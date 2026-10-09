import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/core/tools/logger.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An accepted, signed endpoint list (see `deploy/endpoints/APP_SPEC.md` in
/// the panel repository).
class SignedEndpointList {
  const SignedEndpointList({
    required this.version,
    required this.api,
    required this.web,
    required this.lists,
    required this.raw,
  });

  final int version;
  final List<String> api;
  final List<String> web;
  final List<String> lists;

  /// The file exactly as received, kept so it can be verified again.
  final String raw;
}

/// Verification of the signed list: key id, ECDSA P-256 / SHA-256 signature
/// over the decoded payload bytes, payload shape and version.
abstract final class EndpointListVerifier {
  /// Returns the list when every rule holds, otherwise null (one log line,
  /// nothing the user sees). [currentVersion] is the version already stored;
  /// the new one must be greater.
  static SignedEndpointList? verify(
    String raw, {
    int? currentVersion,
    String? publicKeyPem,
    String? keyId,
    void Function(String message)? log,
  }) {
    void reject(String reason) =>
        (log ?? _defaultLog)('endpoint list rejected: $reason');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        reject('not an object');
        return null;
      }
      if (decoded['key_id'] != (keyId ?? AppEnvironment.endpointKeyId)) {
        reject('unknown key id');
        return null;
      }
      final payloadText = decoded['payload'];
      final signatureText = decoded['signature'];
      if (payloadText is! String || signatureText is! String) {
        reject('missing payload or signature');
        return null;
      }
      final payload = base64.decode(payloadText);
      final signature = base64.decode(signatureText);
      final key = _parsePublicKey(
        publicKeyPem ?? AppEnvironment.endpointPublicKeyPem,
      );
      if (!_verifySignature(key, payload, signature)) {
        reject('bad signature');
        return null;
      }
      final body = jsonDecode(utf8.decode(payload));
      if (body is! Map<String, dynamic>) {
        reject('payload is not an object');
        return null;
      }
      if (body['schema'] != 1) {
        reject('unsupported schema');
        return null;
      }
      final version = body['version'];
      if (version is! int) {
        reject('version is not an integer');
        return null;
      }
      final api = _urls(body['api']);
      final web = _urls(body['web']);
      final lists = _urls(body['lists']);
      if (api == null || web == null || lists == null) {
        reject('invalid url arrays');
        return null;
      }
      if (currentVersion != null && version <= currentVersion) {
        reject('version $version is not newer than $currentVersion');
        return null;
      }
      return SignedEndpointList(
        version: version,
        api: api,
        web: web,
        lists: lists,
        raw: raw,
      );
    } catch (_) {
      reject('malformed file');
      return null;
    }
  }

  static void _defaultLog(String message) => ygLogger('[ColituEndpoints] $message');

  /// Non-empty array of https URLs without query or fragment, or null.
  static List<String>? _urls(Object? value) {
    if (value is! List || value.isEmpty) return null;
    final result = <String>[];
    for (final item in value) {
      if (item is! String) return null;
      final uri = Uri.tryParse(item);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        return null;
      }
      result.add(item);
    }
    return result;
  }

  // SubjectPublicKeyInfo of an uncompressed P-256 point: this fixed header,
  // then 0x04 || X || Y.
  static const _spkiPrefix = <int>[
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00,
  ];

  static ECPublicKey _parsePublicKey(String pem) {
    final b64 = pem
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('-----'))
        .join();
    final der = base64.decode(b64);
    if (der.length != _spkiPrefix.length + 65) {
      throw const FormatException('unexpected public key size');
    }
    for (var i = 0; i < _spkiPrefix.length; i++) {
      if (der[i] != _spkiPrefix[i]) {
        throw const FormatException('not a P-256 public key');
      }
    }
    final point = Uint8List.fromList(der.sublist(_spkiPrefix.length));
    final domain = ECDomainParameters('secp256r1');
    final q = domain.curve.decodePoint(point);
    if (q == null) throw const FormatException('bad public point');
    return ECPublicKey(q, domain);
  }

  static bool _verifySignature(
    ECPublicKey key,
    Uint8List message,
    Uint8List derSignature,
  ) {
    final parsed = _parseDerSignature(derSignature);
    if (parsed == null) return false;
    final n = key.parameters!.n;
    final (r, s) = parsed;
    if (r < BigInt.one || r >= n || s < BigInt.one || s >= n) return false;
    final signer = ECDSASigner(SHA256Digest());
    signer.init(false, PublicKeyParameter<ECPublicKey>(key));
    return signer.verifySignature(message, ECSignature(r, s));
  }

  /// DER `SEQUENCE { INTEGER r, INTEGER s }`, nothing after it.
  static (BigInt, BigInt)? _parseDerSignature(Uint8List der) {
    var pos = 0;
    int? readLength() {
      if (pos >= der.length) return null;
      final first = der[pos++];
      if (first < 0x80) return first;
      final count = first & 0x7f;
      if (count == 0 || count > 2 || pos + count > der.length) return null;
      var value = 0;
      for (var i = 0; i < count; i++) {
        value = (value << 8) | der[pos++];
      }
      return value;
    }

    BigInt? readInteger() {
      if (pos >= der.length || der[pos++] != 0x02) return null;
      final length = readLength();
      if (length == null || length == 0 || pos + length > der.length) {
        return null;
      }
      // Negative integers are not valid here.
      if (der[pos] & 0x80 != 0) return null;
      var value = BigInt.zero;
      for (var i = 0; i < length; i++) {
        value = (value << 8) | BigInt.from(der[pos++]);
      }
      return value;
    }

    if (der.isEmpty || der[pos++] != 0x30) return null;
    final seqLength = readLength();
    if (seqLength == null || pos + seqLength != der.length) return null;
    final r = readInteger();
    final s = readInteger();
    if (r == null || s == null || pos != der.length) return null;
    return (r, s);
  }
}

/// Persistence of the accepted list and the base that last worked.
abstract class EndpointStorage {
  Future<String?> readList();
  Future<int?> readVersion();
  Future<void> writeList(String raw, int version);
  Future<String?> readLastWorking();
  Future<void> writeLastWorking(String base);
}

/// App-private storage (SharedPreferences: nothing here is secret, the list
/// is public and signed).
class PreferencesEndpointStorage implements EndpointStorage {
  PreferencesEndpointStorage();

  static const _listKey = 'colituEndpointList';
  static const _versionKey = 'colituEndpointListVersion';
  static const _lastWorkingKey = 'colituApiLastWorkingBase';

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<String?> readList() => _prefs.getString(_listKey);

  @override
  Future<int?> readVersion() => _prefs.getInt(_versionKey);

  @override
  Future<void> writeList(String raw, int version) async {
    await _prefs.setString(_listKey, raw);
    await _prefs.setInt(_versionKey, version);
  }

  @override
  Future<String?> readLastWorking() => _prefs.getString(_lastWorkingKey);

  @override
  Future<void> writeLastWorking(String base) =>
      _prefs.setString(_lastWorkingKey, base);
}

class MemoryEndpointStorage implements EndpointStorage {
  String? list;
  int? version;
  String? lastWorking;

  @override
  Future<String?> readList() async => list;

  @override
  Future<int?> readVersion() async => version;

  @override
  Future<void> writeList(String raw, int version) async {
    list = raw;
    this.version = version;
  }

  @override
  Future<String?> readLastWorking() async => lastWorking;

  @override
  Future<void> writeLastWorking(String base) async => lastWorking = base;
}

/// Base order: the base that last worked first, then the others in list
/// order, without duplicates (trailing slashes ignored).
List<String> orderApiBases(List<String> bases, {String? lastWorking}) {
  String clean(String value) => value.replaceFirst(RegExp(r'/+$'), '');
  final cleaned = <String>[];
  for (final base in bases) {
    final value = clean(base);
    if (value.isNotEmpty && !cleaned.contains(value)) cleaned.add(value);
  }
  final last = lastWorking == null ? null : clean(lastWorking);
  if (last != null && cleaned.remove(last)) cleaned.insert(0, last);
  return cleaned;
}

/// Failover is allowed only for failures before any HTTP response: DNS,
/// refused or timed-out connections, TLS handshake. A read/send timeout is
/// not enough for a request that is not safe to repeat (the body may have
/// been delivered).
bool shouldFailOver(DioException error, String method) {
  if (error.response != null) return false;
  switch (error.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
      return true;
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
      final upper = method.toUpperCase();
      return upper == 'GET' || upper == 'HEAD';
    case DioExceptionType.unknown:
      final inner = error.error;
      return _isSocketOrHandshake(inner);
    case DioExceptionType.badResponse:
    case DioExceptionType.badCertificate:
    case DioExceptionType.cancel:
      return false;
  }
}

bool _isSocketOrHandshake(Object? error) =>
    error is SocketException || error is HandshakeException;

/// Holds the accepted list, picks the bases and refreshes the list.
class EndpointManager {
  EndpointManager({
    EndpointStorage? storage,
    bool? enabled,
    List<String>? mirrors,
    Dio? fetcher,
    DateTime Function()? clock,
  }) : _storage = storage ?? PreferencesEndpointStorage(),
       enabled = enabled ?? !AppEnvironment.hasApiBaseOverride,
       _builtInApiBases = AppEnvironment.apiBasesFor(
         mirrors ?? AppEnvironment.mirrorOrigins,
       ),
       _builtInListUrls = AppEnvironment.listUrlsFor(
         mirrors ?? AppEnvironment.mirrorOrigins,
       ),
       _fetcher = fetcher,
       _clock = clock ?? DateTime.now;

  static final EndpointManager instance = EndpointManager();

  static const refreshInterval = Duration(hours: 6);

  /// False when `COLITU_API_BASE_URL` is set: that single base is used, no
  /// failover and no list refresh.
  final bool enabled;

  final EndpointStorage _storage;
  final List<String> _builtInApiBases;
  final List<String> _builtInListUrls;
  final Dio? _fetcher;
  final DateTime Function() _clock;

  Future<void>? _loading;
  SignedEndpointList? _list;
  String? _lastWorking;
  DateTime? _lastRefresh;
  bool _refreshing = false;

  SignedEndpointList? get acceptedList => _list;

  Future<void> _load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final raw = await _storage.readList();
      if (raw != null) {
        // Verified again: the stored text is never trusted blindly.
        _list = EndpointListVerifier.verify(raw);
      }
      _lastWorking = await _storage.readLastWorking();
    } catch (_) {
      // Unreadable storage: the built-in values are used.
    }
  }

  /// The API bases for the next request, best first.
  Future<List<String>> bases() async {
    if (!enabled) return [AppEnvironment.apiBaseUrl.toString()];
    await _load();
    return orderApiBases(
      _list?.api ?? _builtInApiBases,
      lastWorking: _lastWorking,
    );
  }

  /// Called when [base] answered with an HTTP response.
  Future<void> rememberWorking(String base) async {
    if (!enabled) return;
    final value = base.replaceFirst(RegExp(r'/+$'), '');
    if (value == _lastWorking) return;
    _lastWorking = value;
    try {
      await _storage.writeLastWorking(value);
    } catch (_) {}
  }

  /// Verifies and stores a downloaded file. True when it was accepted.
  Future<bool> accept(String raw) async {
    await _load();
    final list = EndpointListVerifier.verify(raw, currentVersion: _list?.version);
    if (list == null) return false;
    _list = list;
    try {
      await _storage.writeList(list.raw, list.version);
    } catch (_) {}
    return true;
  }

  /// Fetches the list in the background when [refreshInterval] has passed
  /// since the last attempt (the first call always fetches). Never throws.
  Future<void> refreshIfDue() async {
    if (!enabled || _refreshing) return;
    final last = _lastRefresh;
    final now = _clock();
    if (last != null && now.difference(last) < refreshInterval) return;
    _refreshing = true;
    _lastRefresh = now;
    try {
      await _load();
      final urls = _list?.lists ?? _builtInListUrls;
      final dio = _fetcher ?? _newFetcher();
      for (final url in urls) {
        try {
          final response = await dio.get<String>(url);
          final body = response.data;
          if (response.statusCode == 200 &&
              body != null &&
              body.length <= 64 * 1024 &&
              await accept(body)) {
            break;
          }
        } catch (_) {
          // Network errors are silent; the next URL is tried.
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  static Dio _newFetcher() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      followRedirects: false,
      validateStatus: (status) => status != null,
    ),
  );
}

/// Dio interceptor: sends a request to the best base and moves to the next
/// base on network-level failures (see [shouldFailOver]).
class ApiFailoverInterceptor extends Interceptor {
  ApiFailoverInterceptor(this._dio, this._manager);

  final Dio _dio;
  final EndpointManager _manager;

  static const _basesKey = 'colituFailoverBases';
  static const _indexKey = 'colituFailoverIndex';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_manager.enabled || options.extra.containsKey(_basesKey)) {
      return handler.next(options);
    }
    final bases = await _manager.bases();
    if (bases.isNotEmpty) {
      options.baseUrl = bases.first;
      options.extra[_basesKey] = bases;
      options.extra[_indexKey] = 0;
    }
    // Background list refresh, never awaited.
    _manager.refreshIfDue();
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_manager.enabled && response.requestOptions.extra.containsKey(_basesKey)) {
      _manager.rememberWorking(response.requestOptions.baseUrl);
    }
    handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final bases = options.extra[_basesKey];
    if (!_manager.enabled || bases is! List<String>) {
      return handler.next(err);
    }
    if (err.response != null) {
      _manager.rememberWorking(options.baseUrl);
      return handler.next(err);
    }
    final index = options.extra[_indexKey] as int? ?? 0;
    if (index > 0 || !shouldFailOver(err, options.method)) {
      // index > 0: this is already a request re-sent by the loop below.
      return handler.next(err);
    }
    var lastError = err;
    for (var i = 1; i < bases.length; i++) {
      final data = options.data;
      final next = options.copyWith(
        baseUrl: bases[i],
        extra: {...options.extra, _indexKey: i},
        data: data is FormData ? data.clone() : data,
      );
      try {
        final response = await _dio.fetch<Object?>(next);
        return handler.resolve(response);
      } on DioException catch (error) {
        lastError = error;
        if (error.response != null || !shouldFailOver(error, options.method)) {
          break;
        }
      }
    }
    handler.next(lastError);
  }
}
