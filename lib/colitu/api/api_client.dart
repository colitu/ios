import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/cert_pins.dart';
import 'package:colitu_vpn/colitu/api/endpoint_list.dart';
import 'package:colitu_vpn/colitu/api/models/auth_models.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/core/tools/logger.dart';

typedef JsonDecoder<T> = T Function(Object? json);

class APIClient {
  static final APIClient _singleton = APIClient._internal();

  factory APIClient() => _singleton;

  APIClient._internal()
    : _dio = _buildDio(),
      _refreshDio = _buildDio(),
      _tokenStore = SecureTokenStore();

  /// Both clients start at the preferred base and fail over through
  /// [ApiFailoverInterceptor] (not when `COLITU_API_BASE_URL` is set).
  static Dio _buildDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: APIEndpoint.baseUrl.toString(),
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
        validateStatus: (status) => status != null,
        // The API never redirects; a redirect (captive portal, CDN) would
        // carry the device id to another host and return a page, not JSON.
        followRedirects: false,
      ),
    );
    // Pinned trust (see CertPins); the log goes before the failover.
    dio.httpClientAdapter = CertPins.adapter();
    dio.interceptors.add(CertPinLogInterceptor());
    if (EndpointManager.instance.enabled) {
      dio.interceptors.add(ApiFailoverInterceptor(dio, EndpointManager.instance));
    }
    return dio;
  }

  @visibleForTesting
  APIClient.testing({
    required Dio dio,
    required Dio refreshDio,
    required SecureTokenStore tokenStore,
  }) : _dio = dio,
       _refreshDio = refreshDio,
       _tokenStore = tokenStore;

  final Dio _dio;
  final Dio _refreshDio;
  final SecureTokenStore _tokenStore;
  Future<bool>? _refreshInFlight;
  static const _maxRetryAttempts = 2;
  static const _retryDelays = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];

  Future<T> get<T>(
    String path,
    JsonDecoder<T> decoder, {
    Map<String, dynamic>? queryParameters,
    bool authenticated = true,
    Map<String, dynamic>? headers,
    void Function(Response<dynamic>)? onResponse,
  }) async {
    return _request(
      path,
      decoder,
      method: 'GET',
      queryParameters: queryParameters,
      authenticated: authenticated,
      requestHeaders: headers,
      onResponse: onResponse,
    );
  }

  Future<T> post<T>(
    String path,
    JsonDecoder<T> decoder, {
    Object? data,
    bool authenticated = true,
    Map<String, dynamic>? headers,
  }) async {
    return _request(
      path,
      decoder,
      method: 'POST',
      data: data,
      authenticated: authenticated,
      requestHeaders: headers,
    );
  }

  Future<T> patch<T>(
    String path,
    JsonDecoder<T> decoder, {
    Object? data,
    bool authenticated = true,
  }) async {
    return _request(
      path,
      decoder,
      method: 'PATCH',
      data: data,
      authenticated: authenticated,
    );
  }

  Future<T> put<T>(
    String path,
    JsonDecoder<T> decoder, {
    Object? data,
    bool authenticated = true,
  }) => _request(
    path,
    decoder,
    method: 'PUT',
    data: data,
    authenticated: authenticated,
  );

  Future<T> delete<T>(
    String path,
    JsonDecoder<T> decoder, {
    Object? data,
    bool authenticated = true,
  }) async {
    return _request(
      path,
      decoder,
      method: 'DELETE',
      data: data,
      authenticated: authenticated,
    );
  }

  /// POST for requests the user repeats by hand anyway (verification codes,
  /// support messages): an expired access token is refreshed once and the
  /// request sent again. [data] is a builder because a FormData body cannot
  /// be sent twice.
  Future<T> postRenewing<T>(
    String path,
    JsonDecoder<T> decoder, {
    required Object Function() data,
  }) async {
    try {
      return await post(path, decoder, data: data());
    } on APIException catch (error) {
      if (error.statusCode != 401 || error.terminalAuthFailure) rethrow;
      if (!await _refreshTokenSingleFlight()) rethrow;
      return post(path, decoder, data: data());
    }
  }

  /// PUT for idempotent updates (the preferred server): like [postRenewing],
  /// an expired access token is refreshed once and the request sent again.
  /// Without it a server switch right after the token expired failed with
  /// "your session ended" although the session was fine.
  Future<T> putRenewing<T>(
    String path,
    JsonDecoder<T> decoder, {
    required Object Function() data,
  }) async {
    try {
      return await put(path, decoder, data: data());
    } on APIException catch (error) {
      if (error.statusCode != 401 || error.terminalAuthFailure) rethrow;
      if (!await _refreshTokenSingleFlight()) rethrow;
      return put(path, decoder, data: data());
    }
  }

  /// Raw bytes of an authorized download (support attachments).
  Future<Uint8List> getBytes(String path, {bool retried = false}) async {
    final tokens = await _tokenStore.readTokens();
    final deviceId = await _tokenStore.readDeviceId();
    // Stopped while downloading once it is larger than any attachment: the
    // whole body would otherwise be held in memory first.
    final cancel = CancelToken();
    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        path,
        cancelToken: cancel,
        onReceiveProgress: (received, total) {
          if (received > maxDownloadBytes || total > maxDownloadBytes) {
            cancel.cancel('too large');
          }
        },
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 60),
          headers: {
            'X-App-Name': AppEnvironment.appName,
            'X-Client-Platform': _clientPlatform,
            if (tokens != null) 'Authorization': 'Bearer ${tokens.accessToken}',
            if (deviceId != null && deviceId.isNotEmpty) 'X-Device-ID': deviceId,
          },
        ),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw const APIException(APIErrorCode.unknown, 'Attachment is too large');
      }
      throw APIException.fromDio(error);
    }
    if (response.statusCode == 401 && !retried && await _refreshTokenSingleFlight()) {
      return getBytes(path, retried: true);
    }
    if (response.statusCode == null || response.statusCode! >= 300 || response.data == null) {
      throw APIException(APIErrorCode.unknown, 'Download failed', statusCode: response.statusCode);
    }
    if (response.data!.length > maxDownloadBytes) {
      throw APIException(APIErrorCode.unknown, 'Attachment is too large', statusCode: response.statusCode);
    }
    return Uint8List.fromList(response.data!);
  }

  Future<T> getWithFallback<T>(
    List<String> paths,
    JsonDecoder<T> decoder, {
    Map<String, dynamic>? queryParameters,
  }) async {
    APIException? lastError;
    for (final path in paths) {
      try {
        return await get(path, decoder, queryParameters: queryParameters);
      } on APIException catch (error) {
        lastError = error;
        if (!_canTryFallback(error)) {
          rethrow;
        }
      }
    }
    throw lastError ??
        const APIException(APIErrorCode.unknown, 'Request failed');
  }

  Future<T> _request<T>(
    String path,
    JsonDecoder<T> decoder, {
    required String method,
    Map<String, dynamic>? queryParameters,
    Object? data,
    bool authenticated = true,
    bool tokenRefreshed = false,
    int retryAttempt = 0,
    Map<String, dynamic>? requestHeaders,
    void Function(Response<dynamic>)? onResponse,
  }) async {
    Map<String, dynamic> headers = const {};
    try {
      headers = <String, dynamic>{
        'X-App-Name': AppEnvironment.appName,
        'X-Bundle-ID': AppEnvironment.appBundleId,
        'X-Client-Platform': _clientPlatform,
        'Accept': Headers.jsonContentType,
        'Content-Type': Headers.jsonContentType,
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      };
      if (requestHeaders != null) {
        headers.addAll(requestHeaders);
      }
      if (data is FormData) {
        // Dio writes multipart/form-data with the boundary itself.
        headers.remove('Content-Type');
      }
      if (authenticated) {
        final tokens = await _tokenStore.readTokens();
        if (tokens != null) {
          headers['Authorization'] = 'Bearer ${tokens.accessToken}';
        }
        final deviceId = await _tokenStore.readDeviceId();
        if (deviceId != null && deviceId.isNotEmpty) {
          headers['X-Device-ID'] = deviceId;
        }
      }

      _debugLogRequest(
        method: method,
        path: path,
        queryParameters: queryParameters,
        headers: headers,
        data: data,
        retryAttempt: retryAttempt,
      );
      final response = await _dio.request<Object?>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: Options(method: method, headers: headers),
      );
      onResponse?.call(response);
      _debugLogResponse(
        path: path,
        queryParameters: queryParameters,
        response: response,
        retryAttempt: retryAttempt,
      );
      final status = response.statusCode;
      if (status == 304) {
        return decoder(null);
      }
      if (authenticated &&
          _safeMethod(method) &&
          status == 401 &&
          !tokenRefreshed) {
        _debugLog(
          'received 401 for $path; waiting for refresh single-flight retryAttempt=$retryAttempt',
        );
        final refreshed = await _refreshTokenSingleFlight();
        if (refreshed) {
          return await _request(
            path,
            decoder,
            method: method,
            queryParameters: queryParameters,
            data: data,
            authenticated: authenticated,
            tokenRefreshed: true,
            retryAttempt: retryAttempt,
            requestHeaders: requestHeaders,
            onResponse: onResponse,
          );
        }
      }
      if (_shouldRetryStatus(method, status, retryAttempt)) {
        await _waitBeforeRetry(
          path: path,
          retryAttempt: retryAttempt,
          statusCode: status,
        );
        return await _request(
          path,
          decoder,
          method: method,
          queryParameters: queryParameters,
          data: data,
          authenticated: authenticated,
          tokenRefreshed: tokenRefreshed,
          retryAttempt: retryAttempt + 1,
          requestHeaders: requestHeaders,
          onResponse: onResponse,
        );
      }
      if (!_isSuccessfulStatus(status)) {
        _debugLogFailedRequest(
          method: method,
          path: path,
          queryParameters: queryParameters,
          headers: headers,
          data: data,
          response: response,
          retryAttempt: retryAttempt,
        );
        throw APIException.fromResponse(response);
      }
      return decoder(response.data);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      _debugLogDioError(
        method: method,
        path: path,
        queryParameters: queryParameters,
        headers: headers,
        data: data,
        error: error,
        retryAttempt: retryAttempt,
      );
      if (authenticated &&
          _safeMethod(method) &&
          status == 401 &&
          !tokenRefreshed) {
        _debugLog(
          'received dio 401 for $path; waiting for refresh single-flight '
          'retryAttempt=$retryAttempt',
        );
        final refreshed = await _refreshTokenSingleFlight();
        if (refreshed) {
          return _request(
            path,
            decoder,
            method: method,
            queryParameters: queryParameters,
            data: data,
            authenticated: authenticated,
            tokenRefreshed: true,
            retryAttempt: retryAttempt,
            requestHeaders: requestHeaders,
            onResponse: onResponse,
          );
        }
      }
      if (_shouldRetryDio(method, error, retryAttempt)) {
        await _waitBeforeRetry(
          path: path,
          retryAttempt: retryAttempt,
          statusCode: status,
          errorType: error.type,
        );
        return _request(
          path,
          decoder,
          method: method,
          queryParameters: queryParameters,
          data: data,
          authenticated: authenticated,
          tokenRefreshed: tokenRefreshed,
          retryAttempt: retryAttempt + 1,
          requestHeaders: requestHeaders,
          onResponse: onResponse,
        );
      }
      throw APIException.fromDio(error);
    } on FormatException catch (error) {
      throw APIException(APIErrorCode.decodingFailed, error.message);
    }
  }

  Future<bool> _refreshTokenSingleFlight() {
    final existing = _refreshInFlight;
    if (existing != null) {
      _debugLog('refresh already in flight; joining existing refresh');
      return existing;
    }
    _debugLog('starting refresh single-flight');
    final future = _performRefreshToken();
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
        _debugLog('refresh single-flight cleared');
      }
    });
  }

  /// Waits until a token refresh that is running has finished (sign-out
  /// sends the newest refresh token to be revoked).
  Future<void> settleRefresh() async {
    final inFlight = _refreshInFlight;
    if (inFlight == null) return;
    try {
      await inFlight;
    } catch (_) {
      // The outcome does not matter here.
    }
  }

  /// The panel's answers to /auth/refresh that mean the refresh token is
  /// gone for good (wrong, expired or revoked).
  static const _refreshRejectedCodes = {
    'AUTH_INVALID_CREDENTIALS',
    'AUTH_REFRESH_REUSED',
    'DEVICE_TOKEN_MISMATCH',
    'DEVICE_REVOKED',
    'DEVICE_NOT_FOUND',
  };

  /// Largest attachment the app downloads (support files are at most 10 MB).
  static const maxDownloadBytes = 25 << 20;

  Future<bool> _performRefreshToken() async {
    final generation = _tokenStore.sessionGeneration;
    final tokens = await _tokenStore.readTokens();
    final refreshToken = tokens?.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      _debugLog('refresh skipped: no refresh token');
      return false;
    }
    try {
      _debugLog('posting refresh request');
      final headers = <String, dynamic>{};
      final deviceId = await _tokenStore.readDeviceId();
      if (deviceId != null && deviceId.isNotEmpty) {
        headers['X-Device-ID'] = deviceId;
      }
      final response = await _refreshDio.post<Map<String, dynamic>>(
        APIEndpoint.authRefresh,
        data: RefreshTokenRequest(refreshToken).toJson(),
        options: headers.isEmpty ? null : Options(headers: headers),
      );
      if (generation != _tokenStore.sessionGeneration) {
        // Signed out or signed in again while this ran: the answer belongs
        // to a session that no longer exists.
        _debugLog('refresh answer dropped: session changed meanwhile');
        return false;
      }
      if (!_isSuccessfulStatus(response.statusCode)) {
        _debugLog('refresh failed statusCode=${response.statusCode}');
        final error = APIException.fromResponse(response);
        // Only the panel's own error codes end the session. A 401/403 page
        // from a captive portal, CDN or filter in between must not sign the
        // user out and wipe the offline configuration.
        if (error.terminalAuthFailure ||
            (response.statusCode == 401 &&
                _refreshRejectedCodes.contains(error.backendCode))) {
          _debugLog(
            'refresh failed with terminal auth response; clearing stored auth state',
          );
          throw APIException(
            error.code,
            error.message,
            statusCode: response.statusCode,
            terminalAuthFailure: true,
          );
        }
        return false;
      }
      final auth = AuthTokenResponse.fromJson(response.data ?? {});
      if (auth.tokens.refreshToken == null ||
          auth.tokens.refreshToken!.isEmpty) {
        _debugLog('refresh response missing rotated refresh token');
        return false;
      }
      if (!await _tokenStore.saveTokensIfCurrent(auth.tokens, generation)) {
        _debugLog('refreshed tokens dropped: session changed meanwhile');
        return false;
      }
      _debugLog('refresh succeeded; tokens rotated and stored');
      return true;
    } on APIException catch (error) {
      _debugLog(
        'refresh failed apiError code=${error.code} terminal=${error.terminalAuthFailure}',
      );
      if (error.terminalAuthFailure) {
        if (generation != _tokenStore.sessionGeneration) {
          // A session that is already gone; the current one is untouched.
          return false;
        }
        await _tokenStore.clear();
        rethrow;
      }
      return false;
    } catch (error) {
      _debugLog('refresh failed errorType=${error.runtimeType}');
      return false;
    }
  }

  bool _isSuccessfulStatus(int? status) =>
      status != null && status >= 200 && status < 300;

  bool _shouldRetryStatus(String method, int? status, int retryAttempt) {
    return _safeMethod(method) &&
        retryAttempt < _maxRetryAttempts &&
        status == 503;
  }

  bool _shouldRetryDio(String method, DioException error, int retryAttempt) {
    if (!_safeMethod(method) || retryAttempt >= _maxRetryAttempts) return false;
    final status = error.response?.statusCode;
    if (status == 503) return true;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout;
  }

  bool _safeMethod(String method) => method == 'GET' || method == 'HEAD';

  Future<void> _waitBeforeRetry({
    required String path,
    required int retryAttempt,
    int? statusCode,
    DioExceptionType? errorType,
  }) async {
    final delay =
        _retryDelays[retryAttempt.clamp(0, _retryDelays.length - 1).toInt()];
    _debugLog(
      'retrying $path count=${retryAttempt + 1} statusCode=$statusCode type=$errorType delayMs=${delay.inMilliseconds}',
    );
    await Future.delayed(delay);
  }

  bool _canTryFallback(APIException error) {
    return error.statusCode == 404 || error.code == APIErrorCode.configMissing;
  }

  void _debugLogRequest({
    required String method,
    required String path,
    required Map<String, dynamic>? queryParameters,
    required Map<String, dynamic> headers,
    required Object? data,
    required int retryAttempt,
  }) {
    _debugLog('$method route=$path retryCount=$retryAttempt');
  }

  void _debugLogResponse({
    required String path,
    required Map<String, dynamic>? queryParameters,
    required Response<Object?> response,
    required int retryAttempt,
  }) {
    _debugLog(
      'response route=$path statusCode=${response.statusCode} retryCount=$retryAttempt',
    );
    _debugLogEndpointDiagnostic(
      path: path,
      queryParameters: queryParameters,
      statusCode: response.statusCode,
      body: response.data,
    );
  }

  void _debugLogDioError({
    required String method,
    required String path,
    required Map<String, dynamic>? queryParameters,
    required Map<String, dynamic> headers,
    required Object? data,
    required DioException error,
    required int retryAttempt,
  }) {
    _debugLog(
      'dioError route=$path statusCode=${error.response?.statusCode} type=${error.type} retryCount=$retryAttempt',
    );
    _debugLogFailedRequest(
      method: method,
      path: path,
      queryParameters: queryParameters,
      headers: headers,
      data: data,
      response: error.response,
      errorType: error.type,
      retryAttempt: retryAttempt,
    );
    _debugLogEndpointDiagnostic(
      path: path,
      queryParameters: queryParameters,
      statusCode: error.response?.statusCode,
      body: error.response?.data,
    );
  }

  void _debugLogFailedRequest({
    required String method,
    required String path,
    required Map<String, dynamic>? queryParameters,
    required Map<String, dynamic> headers,
    required Object? data,
    required int retryAttempt,
    Response<dynamic>? response,
    DioExceptionType? errorType,
  }) {
    _debugLog(
      'failedRequest method=$method route=$path statusCode=${response?.statusCode} type=$errorType retryCount=$retryAttempt',
    );
    if (response?.statusCode == 401) {
      final authorizationPresent = headers.containsKey('Authorization');
      final deviceIdPresent = headers.containsKey('X-Device-ID');
      _debugLog(
        'diagnostic=auth header missing, token expired, or secure storage token mismatch authorizationPresent=$authorizationPresent deviceIdPresent=$deviceIdPresent',
      );
    }
  }

  void _debugLogEndpointDiagnostic({
    required String path,
    required Map<String, dynamic>? queryParameters,
    required int? statusCode,
    required Object? body,
  }) {
    if (statusCode == null || statusCode < 500) return;
    if (path == APIEndpoint.vpnServers) {
      _debugLog(
        'diagnostic=server list endpoint unavailable or baseUrl/auth/env mismatch url=${_fullUrl(path, queryParameters)} statusCode=$statusCode body=${_safeResponseBody(path, body)}',
      );
      return;
    }
    if (path == APIEndpoint.vpnConfig) {
      _debugLog(
        'diagnostic=config endpoint backend unavailable or contract mismatch selectedServerId=${_selectedServerId(queryParameters)} url=${_fullUrl(path, queryParameters)} statusCode=$statusCode body=${_safeResponseBody(path, body)}',
      );
    }
  }

  String _safeResponseBody(String _, Object? data) {
    return _safeJson(data);
  }

  String _safeJson(Object? value) {
    try {
      final sanitized = _sanitize(value);
      final text = sanitized is String ? sanitized : jsonEncode(sanitized);
      return text.length <= 800 ? text : '${text.substring(0, 800)}...';
    } catch (_) {
      return '<unprintable>';
    }
  }

  Object? _sanitize(Object? value) {
    if (value is Map) {
      return value.map((key, child) {
        final keyText = '$key'.toLowerCase();
        final sensitive =
            keyText.contains('token') ||
            keyText == 'authorization' ||
            keyText == 'cookie' ||
            keyText == 'set-cookie' ||
            keyText.contains('tokenhash') ||
            keyText.contains('token_hash') ||
            keyText.contains('password') ||
            keyText.contains('secret') ||
            keyText.contains('credential') ||
            keyText.contains('device') ||
            keyText.contains('privatekey') ||
            keyText == 'config' ||
            keyText.contains('outbound') ||
            keyText.contains('raw') ||
            keyText.contains('subscriptionurl');
        if (sensitive) {
          final redacted = keyText == 'authorization' ? 'Bearer ***' : '***';
          return MapEntry(key, redacted);
        }
        return MapEntry(key, _sanitize(child));
      });
    }
    if (value is List) {
      return value.map(_sanitize).toList(growable: false);
    }
    return value;
  }

  String _fullUrl(String path, Map<String, dynamic>? queryParameters) {
    final base = Uri.parse(_dio.options.baseUrl);
    final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
    final endpointPath = path.replaceFirst(RegExp(r'^/+'), '');
    final combinedPath = [
      if (basePath.isNotEmpty) basePath,
      endpointPath,
    ].join('/');
    final query = <String, dynamic>{
      ...base.queryParameters,
      if (queryParameters != null) ...queryParameters,
    };
    return base
        .replace(
          path: combinedPath.startsWith('/') ? combinedPath : '/$combinedPath',
          queryParameters: query.isEmpty
              ? null
              : query.map((key, value) => MapEntry(key, '$value')),
        )
        .toString();
  }

  String _selectedServerId(Map<String, dynamic>? queryParameters) {
    final value = queryParameters?['serverId'] ?? queryParameters?['server_id'];
    final text = '${value ?? ''}'.trim();
    return text.isEmpty ? '<none>' : text;
  }

  String get _clientPlatform {
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  void _debugLog(String message) {
    if (kDebugMode && AppEnvironment.enableApiDebugLogging) {
      ygLogger('[ColituAPI] $message');
    }
  }
}
