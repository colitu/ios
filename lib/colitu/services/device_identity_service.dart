import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentityService {
  DeviceIdentityService({SecureTokenStore? tokenStore})
    : _tokenStore = tokenStore ?? SecureTokenStore();

  final SecureTokenStore _tokenStore;

  Future<String> deviceKey() async {
    final existing = await _tokenStore.readDeviceKey();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    // Builds before 5.0.1 stored the locally generated key in the backend ID
    // slot. Preserve it during upgrade, then let device registration replace
    // that slot with the authoritative backend device ID.
    final legacy = await _tokenStore.readDeviceId();
    final key = legacy != null && legacy.isNotEmpty
        ? legacy
        : const Uuid().v4();
    await _tokenStore.saveDeviceKey(key);
    return key;
  }

  Future<String> rotateDeviceKey() async {
    final key = const Uuid().v4();
    await _tokenStore.saveDeviceKey(key);
    return key;
  }

  Future<String?> backendDeviceId() => _tokenStore.readDeviceId();

  /// Kept for social sign-in payload compatibility while those providers use
  /// the local persistent device key.
  Future<String> deviceId() => deviceKey();
}
