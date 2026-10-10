import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'parallel 401 responses share one refresh and retry with rotated token',
    () async {
      final tokenStore = _FakeTokenStore(
        const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
      );
      final protectedAuthorizationHeaders = <String?>[];
      var refreshCalls = 0;

      final protectedDio = _testDio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          final authorization = options.headers['Authorization'] as String?;
          protectedAuthorizationHeaders.add(authorization);
          if (authorization == 'Bearer access-2') {
            return _jsonResponse({'ok': true});
          }
          return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
        });
      final refreshDio = _testDio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          refreshCalls += 1;
          expect(options.path, APIEndpoint.authRefresh);
          expect(
            (options.data as Map<String, dynamic>)['refresh_token'],
            'refresh-1',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonResponse({
            'access_token': 'access-2',
            'refresh_token': 'refresh-2',
            'token_type': 'Bearer',
            'expires_in': 900,
          });
        });

      final client = APIClient.testing(
        dio: protectedDio,
        refreshDio: refreshDio,
        tokenStore: tokenStore,
      );

      final responses = await Future.wait([
        client.get<Map<String, dynamic>>('/protected', _decodeMap),
        client.get<Map<String, dynamic>>('/protected', _decodeMap),
        client.get<Map<String, dynamic>>('/protected', _decodeMap),
      ]);

      expect(responses, everyElement({'ok': true}));
      expect(refreshCalls, 1);
      expect(tokenStore.tokens?.accessToken, 'access-2');
      expect(tokenStore.tokens?.refreshToken, 'refresh-2');
      expect(tokenStore.clearCalls, 0);
      expect(
        protectedAuthorizationHeaders.where(
          (header) => header == 'Bearer access-2',
        ),
        hasLength(3),
      );
    },
  );

  test(
    'refresh without rotated refreshToken keeps tokens and does not retry',
    () async {
      final tokenStore = _FakeTokenStore(
        const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
      );
      final protectedAuthorizationHeaders = <String?>[];
      var refreshCalls = 0;

      final protectedDio = _testDio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          protectedAuthorizationHeaders.add(
            options.headers['Authorization'] as String?,
          );
          return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
        });
      final refreshDio = _testDio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          refreshCalls += 1;
          expect(
            (options.data as Map<String, dynamic>)['refresh_token'],
            'refresh-1',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonResponse({
            'access_token': 'access-2',
            'token_type': 'Bearer',
            'expires_in': 900,
          });
        });

      final client = APIClient.testing(
        dio: protectedDio,
        refreshDio: refreshDio,
        tokenStore: tokenStore,
      );

      final errors = await Future.wait([
        _captureError(
          client.get<Map<String, dynamic>>('/protected', _decodeMap),
        ),
        _captureError(
          client.get<Map<String, dynamic>>('/protected', _decodeMap),
        ),
        _captureError(
          client.get<Map<String, dynamic>>('/protected', _decodeMap),
        ),
      ]);

      expect(errors, everyElement(isNotNull));
      expect(refreshCalls, 1);
      expect(tokenStore.tokens?.accessToken, 'access-1');
      expect(tokenStore.tokens?.refreshToken, 'refresh-1');
      expect(tokenStore.clearCalls, 0);
      expect(protectedAuthorizationHeaders, hasLength(3));
      expect(protectedAuthorizationHeaders, everyElement('Bearer access-1'));
    },
  );

  test(
    'invalid refresh with concurrent waiters clears the expired session',
    () async {
      final tokenStore = _FakeTokenStore(
        const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
      );
      final protectedAuthorizationHeaders = <String?>[];
      var refreshCalls = 0;

      final protectedDio = _testDio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          protectedAuthorizationHeaders.add(
            options.headers['Authorization'] as String?,
          );
          return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
        });
      final refreshDio = _testDio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          refreshCalls += 1;
          expect(
            (options.data as Map<String, dynamic>)['refresh_token'],
            'refresh-1',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // The panel's answer to a wrong or expired refresh token.
          return _jsonResponse({
            'error': {'code': 'AUTH_INVALID_CREDENTIALS', 'message': 'invalid credentials'},
          }, statusCode: 401);
        });

      final client = APIClient.testing(
        dio: protectedDio,
        refreshDio: refreshDio,
        tokenStore: tokenStore,
      );

      final errors = await Future.wait([
        _captureError(
          client.get<Map<String, dynamic>>('/protected', _decodeMap),
        ),
        _captureError(
          client.get<Map<String, dynamic>>('/protected', _decodeMap),
        ),
        _captureError(
          client.get<Map<String, dynamic>>('/protected', _decodeMap),
        ),
      ]);

      expect(errors, everyElement(isNotNull));
      expect(refreshCalls, 1);
      expect(tokenStore.tokens, isNull);
      expect(tokenStore.clearCalls, 1);
      expect(protectedAuthorizationHeaders, hasLength(3));
      expect(protectedAuthorizationHeaders, everyElement('Bearer access-1'));
    },
  );

  test('terminal failed refresh clears tokens exactly once', () async {
    final tokenStore = _FakeTokenStore(
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
    var refreshCalls = 0;

    final protectedDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
      });
    final refreshDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        refreshCalls += 1;
        return _jsonResponse({
          'error': 'REFRESH_TOKEN_COMPROMISED',
          'code': 'REFRESH_TOKEN_COMPROMISED',
          'terminal': true,
          'message': 'Refresh token reuse detected',
        }, statusCode: 401);
      });

    final client = APIClient.testing(
      dio: protectedDio,
      refreshDio: refreshDio,
      tokenStore: tokenStore,
    );

    final errors = await Future.wait([
      _captureError(client.get<Map<String, dynamic>>('/protected', _decodeMap)),
      _captureError(client.get<Map<String, dynamic>>('/protected', _decodeMap)),
      _captureError(client.get<Map<String, dynamic>>('/protected', _decodeMap)),
    ]);

    expect(errors, everyElement(isNotNull));
    expect(refreshCalls, 1);
    expect(tokenStore.tokens, isNull);
    expect(tokenStore.clearCalls, 1);
  });

  test('terminal auth code without terminal flag clears tokens', () async {
    final tokenStore = _FakeTokenStore(
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );

    final protectedDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
      });
    final refreshDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return _jsonResponse({
          'error': 'USER_DISABLED',
          'code': 'USER_DISABLED',
          'message': 'User disabled',
        }, statusCode: 401);
      });

    final client = APIClient.testing(
      dio: protectedDio,
      refreshDio: refreshDio,
      tokenStore: tokenStore,
    );

    await _captureError(
      client.get<Map<String, dynamic>>('/protected', _decodeMap),
    );

    expect(tokenStore.tokens, isNull);
    expect(tokenStore.clearCalls, 1);
  });

  test('a 403 page from a proxy during refresh keeps the session', () async {
    final tokenStore = _FakeTokenStore(
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
    final protectedDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
      });
    final refreshDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        // A captive portal or CDN block page, not the panel.
        return ResponseBody.fromString(
          '<html>blocked</html>',
          403,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        );
      });
    final client = APIClient.testing(
      dio: protectedDio,
      refreshDio: refreshDio,
      tokenStore: tokenStore,
    );

    await _captureError(
      client.get<Map<String, dynamic>>('/protected', _decodeMap),
    );

    expect(tokenStore.clearCalls, 0);
    expect(tokenStore.tokens?.refreshToken, 'refresh-1');
  });

  test('a refresh that finishes after sign-out does not restore the session', () async {
    final tokenStore = _FakeTokenStore(
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<void>();
    final protectedDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return _jsonResponse({'error': 'UNAUTHORIZED'}, statusCode: 401);
      });
    final refreshDio = _testDio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        refreshStarted.complete();
        await finishRefresh.future;
        return _jsonResponse({
          'access_token': 'access-2',
          'refresh_token': 'refresh-2',
          'token_type': 'Bearer',
          'expires_in': 900,
        });
      });
    final client = APIClient.testing(
      dio: protectedDio,
      refreshDio: refreshDio,
      tokenStore: tokenStore,
    );

    final request = _captureError(
      client.get<Map<String, dynamic>>('/protected', _decodeMap),
    );
    await refreshStarted.future;
    await tokenStore.clear(); // the user signs out meanwhile
    finishRefresh.complete();
    await request;

    expect(tokenStore.tokens, isNull);
  });
}

Map<String, dynamic> _decodeMap(Object? json) => json as Map<String, dynamic>;

Future<Object?> _captureError(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

Dio _testDio() {
  return Dio(
    BaseOptions(
      baseUrl: 'https://api.test',
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
      validateStatus: (status) => status != null,
    ),
  );
}

ResponseBody _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class _FakeTokenStore implements SecureTokenStore {
  _FakeTokenStore(this.tokens);

  var _generation = 0;

  @override
  int get sessionGeneration => _generation;

  @override
  void beginSession() => _generation++;

  @override
  Future<bool> saveTokensIfCurrent(AuthTokens tokens, int generation) async {
    if (generation != _generation) return false;
    this.tokens = tokens;
    return true;
  }

  String? pendingEmail;

  @override
  Future<String?> readPendingVerificationEmail() async => pendingEmail;

  @override
  Future<void> savePendingVerificationEmail(String? email) async => pendingEmail = email;

  AuthTokens? tokens;
  String? userId;
  String? deviceId = 'device-1';
  String? deviceKey = 'device-key-1';
  String? lastGoodConfig;
  String? configEtag;
  String? runtimePolicy;
  var clearCalls = 0;

  @override
  Future<void> clear() async {
    _generation++;
    clearCalls += 1;
    tokens = null;
    userId = null;
  }

  @override
  Future<String?> readDeviceId() async => deviceId;

  @override
  Future<String?> readDeviceKey() async => deviceKey;

  @override
  Future<AuthTokens?> readTokens() async => tokens;

  @override
  Future<String?> readUserId() async => userId;

  @override
  Future<void> saveDeviceId(String value) async {
    deviceId = value;
  }

  @override
  Future<void> clearLastGoodConfig() async {
    lastGoodConfig = null;
    configEtag = null;
  }

  @override
  Future<void> clearRuntimePolicy() async => runtimePolicy = null;

  @override
  Future<String?> readConfigEtag() async => configEtag;
  String? recoverySet;
  int? recoveryAttempt;

  @override
  Future<String?> readRecoverySet() async => recoverySet;

  @override
  Future<void> saveRecoverySet(String value) async => recoverySet = value;

  @override
  Future<void> clearRecoverySet() async => recoverySet = null;

  @override
  Future<int?> readRecoveryAttempt() async => recoveryAttempt;

  @override
  Future<void> saveRecoveryAttempt(int epochMs) async =>
      recoveryAttempt = epochMs;


  @override
  Future<String?> readLastGoodConfig() async => lastGoodConfig;

  @override
  Future<String?> readRuntimePolicy() async => runtimePolicy;

  @override
  Future<void> saveDeviceKey(String value) async {
    deviceKey = value;
  }

  @override
  Future<void> saveConfigEtag(String value) async => configEtag = value;

  @override
  Future<void> saveLastGoodConfig(String value) async => lastGoodConfig = value;

  @override
  Future<void> saveRuntimePolicy(String value) async => runtimePolicy = value;

  @override
  Future<void> saveTokens(AuthTokens tokens, {String? userId}) async {
    this.tokens = tokens;
    this.userId = userId;
  }
}
