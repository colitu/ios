import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthTokens {
  final String accessToken;
  final String? refreshToken;

  const AuthTokens({required this.accessToken, this.refreshToken});
}

class SecureTokenStore {
  static final SecureTokenStore _singleton = SecureTokenStore._internal();

  factory SecureTokenStore() => _singleton;

  SecureTokenStore._internal();

  static const _accessTokenKey = 'colitu_access_token';
  static const _refreshTokenKey = 'colitu_refresh_token';
  static const _userIdKey = 'colitu_user_id';
  static const _deviceIdKey = 'colitu_device_id';
  static const _deviceKeyKey = 'colitu_device_key';
  static const _lastGoodConfigKey = 'colitu_xray_lkg';
  static const _configEtagKey = 'colitu_xray_etag';
  static const _runtimePolicyKey = 'colitu_runtime_policy';
  static const _pendingEmailKey = 'colitu_pending_verification_email';
  static const _recoverySetKey = 'colitu_recovery_set';
  static const _recoveryAttemptKey = 'colitu_recovery_attempt';

  static const _allKeys = [
    _accessTokenKey,
    _refreshTokenKey,
    _userIdKey,
    _deviceIdKey,
    _deviceKeyKey,
    _lastGoodConfigKey,
    _configEtagKey,
    _runtimePolicyKey,
    _pendingEmailKey,
    _recoverySetKey,
    _recoveryAttemptKey,
  ];

  /// Set in SharedPreferences once the Keychain items use this-device-only
  /// accessibility. SharedPreferences (unlike the Keychain) is removed with
  /// the app, so a missing marker on an otherwise empty store also means
  /// "installed again".
  static const _keychainMarker = 'colituKeychainThisDevice01';

  // Never copied to another phone by an encrypted backup: two devices sharing
  // one rotating refresh token sign each other out (the panel revokes the
  // token family on reuse), and a restored backup must not carry the last
  // server configuration with its credentials.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // How versions up to 5.4.0 stored the items; only read to move them over.
  final FlutterSecureStorage _legacyStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<void>? _prepared;

  /// Bumped by every sign-out and every new sign-in. A token refresh that
  /// started under an older session must neither bring that session back
  /// after sign-out nor overwrite the tokens of the account signed in since.
  int _generation = 0;

  int get sessionGeneration => _generation;

  // Token writes and deletes run one at a time, so a sign-out can never
  // interleave with a refresh that is halfway through saving its tokens.
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _ready() => _prepared ??= _prepare();

  Future<void> _prepare() async {
    try {
      final prefs = SharedPreferencesAsync();
      if (await prefs.getBool(_keychainMarker) == true) return;
      final reinstalled = (await prefs.getKeys()).isEmpty;
      for (final key in _allKeys) {
        final value = await _legacyStorage.read(key: key);
        if (value == null) continue;
        // The Keychain outlives the app: after a reinstall the previous
        // session, device identity and server configuration are dropped
        // instead of signing the user in again silently.
        await _legacyStorage.delete(key: key);
        if (!reinstalled) {
          await _storage.write(key: key, value: value);
        }
      }
      if (reinstalled) {
        for (final key in _allKeys) {
          await _storage.delete(key: key);
        }
      }
      await prefs.setBool(_keychainMarker, true);
    } catch (_) {
      // Keychain unavailable (device locked before first unlock): try again
      // on the next access instead of losing the session.
      _prepared = null;
    }
  }

  Future<String?> _read(String key) async {
    await _ready();
    return _storage.read(key: key);
  }

  Future<void> _write(String key, String value) async {
    await _ready();
    await _storage.write(key: key, value: value);
  }

  Future<void> _delete(String key) async {
    await _ready();
    await _storage.delete(key: key);
  }

  Future<AuthTokens?> readTokens() async {
    final accessToken = await _read(_accessTokenKey);
    if (accessToken == null || accessToken.isEmpty) {
      return null;
    }
    final refreshToken = await _read(_refreshTokenKey);
    return AuthTokens(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<String?> readUserId() => _read(_userIdKey);

  Future<String?> readDeviceId() => _read(_deviceIdKey);

  Future<void> saveDeviceId(String value) => _write(_deviceIdKey, value);

  Future<String?> readDeviceKey() => _read(_deviceKeyKey);

  Future<void> saveDeviceKey(String value) => _write(_deviceKeyKey, value);

  Future<String?> readLastGoodConfig() => _read(_lastGoodConfigKey);

  Future<void> saveLastGoodConfig(String value) =>
      _write(_lastGoodConfigKey, value);

  Future<void> clearLastGoodConfig() async {
    await _delete(_lastGoodConfigKey);
    await _delete(_configEtagKey);
  }

  Future<String?> readConfigEtag() => _read(_configEtagKey);

  Future<void> saveConfigEtag(String value) => _write(_configEtagKey, value);

  Future<String?> readRuntimePolicy() => _read(_runtimePolicyKey);

  Future<void> saveRuntimePolicy(String value) =>
      _write(_runtimePolicyKey, value);

  Future<void> clearRuntimePolicy() => _delete(_runtimePolicyKey);

  /// Adaptive Connect 3.0 recovery set (the raw JSON of
  /// `GET /client/recovery`): node credentials, so it lives in the Keychain
  /// next to the other secrets and goes with them on sign-out.
  Future<String?> readRecoverySet() => _read(_recoverySetKey);

  Future<void> saveRecoverySet(String value) => _write(_recoverySetKey, value);

  Future<void> clearRecoverySet() => _delete(_recoverySetKey);

  /// When the last fetch of the recovery set was tried (epoch ms).
  Future<int?> readRecoveryAttempt() async =>
      int.tryParse(await _read(_recoveryAttemptKey) ?? '');

  Future<void> saveRecoveryAttempt(int epochMs) =>
      _write(_recoveryAttemptKey, '$epochMs');

  /// Set while the signed-in account still has to confirm this e-mail.
  Future<String?> readPendingVerificationEmail() async {
    final value = await _read(_pendingEmailKey);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> savePendingVerificationEmail(String? email) async {
    if (email == null || email.isEmpty) {
      await _delete(_pendingEmailKey);
    } else {
      await _write(_pendingEmailKey, email);
    }
  }

  /// A new sign-in starts: refreshes still running for the previous session
  /// are discarded.
  void beginSession() => _generation++;

  Future<void> saveTokens(AuthTokens tokens, {String? userId}) =>
      _serial(() => _writeTokens(tokens, userId));

  /// Saves refreshed tokens only while the session they belong to is still
  /// the current one. False when a sign-out or a new sign-in came first.
  Future<bool> saveTokensIfCurrent(AuthTokens tokens, int generation) =>
      _serial(() async {
        if (generation != _generation) return false;
        await _writeTokens(tokens, null);
        return true;
      });

  Future<void> _writeTokens(AuthTokens tokens, String? userId) async {
    await _write(_accessTokenKey, tokens.accessToken);
    if (tokens.refreshToken != null && tokens.refreshToken!.isNotEmpty) {
      await _write(_refreshTokenKey, tokens.refreshToken!);
    }
    if (userId != null && userId.isNotEmpty) {
      await _write(_userIdKey, userId);
    }
  }

  Future<void> clear() {
    // Synchronously, before anything is awaited: a refresh finishing in the
    // meantime sees the new generation and does not save.
    _generation++;
    return _serial(() async {
      await _delete(_accessTokenKey);
      await _delete(_refreshTokenKey);
      await _delete(_userIdKey);
      await _delete(_deviceIdKey);
      await _delete(_lastGoodConfigKey);
      await _delete(_configEtagKey);
      await _delete(_runtimePolicyKey);
      await _delete(_pendingEmailKey);
      await _delete(_recoverySetKey);
      await _delete(_recoveryAttemptKey);
    });
  }
}
