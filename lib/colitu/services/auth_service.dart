import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/models/auth_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/services/device_identity_service.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// A device (a TV) that shows a QR code and waits for a phone to approve it.
class LinkRequest {
  const LinkRequest({required this.code, required this.deviceName, required this.platform, this.country});

  final String code;
  final String deviceName;
  final String platform;
  final String? country;

  factory LinkRequest.fromJson(Map<String, dynamic> json) => LinkRequest(
    code: '${json['code'] ?? ''}',
    deviceName: '${json['device_name'] ?? ''}',
    platform: '${json['platform'] ?? ''}',
    country: (json['country'] as String?)?.trim().isEmpty ?? true ? null : json['country'] as String,
  );

  /// Reads the code out of a scanned QR (https://colitu.com/link?c=CODE) or a
  /// typed "ABCD-2345"; null when it is neither.
  static String? codeOf(String value) {
    var raw = value.trim();
    if (raw.contains('/')) {
      final uri = Uri.tryParse(raw);
      final host = uri?.host.toLowerCase() ?? '';
      if (uri == null || uri.scheme != 'https' || !(host == 'colitu.com' || host.endsWith('.colitu.com')) || uri.path != '/link') {
        return null;
      }
      raw = uri.queryParameters['c'] ?? '';
    }
    final code = raw.toUpperCase().replaceAll(RegExp(r'[-\s]'), '');
    return RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ2-9]{8}$').hasMatch(code) ? code : null;
  }

  /// "ABCD2345" → "ABCD-2345", the way the TV and the website show it.
  static String shown(String code) => code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;
}

/// Sign-in passed the password and now needs the second step: a code from
/// the authenticator app or a recovery code. Two-step sign-in is set up on
/// the website; the app only answers the challenge.
class MfaChallenge {
  const MfaChallenge({
    required this.token,
    required this.email,
    required this.expiresAt,
  });

  final String token;
  final String email;

  /// When the panel stops accepting [token] (`mfa_expires_in`).
  final DateTime expiresAt;

  bool get expired => !DateTime.now().isBefore(expiresAt);
}

/// Thrown by [AuthService.login] when the account uses two-step sign-in.
class MfaRequiredException implements Exception {
  const MfaRequiredException(this.challenge);

  final MfaChallenge challenge;

  @override
  String toString() => 'MfaRequiredException';
}

class AuthService {
  /// Tells the panel this build can answer a two-step challenge; without it
  /// the panel answers `MFA_REQUIRED_UPDATE_APP` for such accounts.
  static const featureHeaders = {'X-Colitu-Features': 'mfa'};

  AuthService({APIClient? client, SecureTokenStore? tokenStore})
    : _client = client ?? APIClient(),
      _tokenStore = tokenStore ?? SecureTokenStore();

  final APIClient _client;
  final SecureTokenStore _tokenStore;
  Future<String>? _deviceRegistrationInFlight;
  bool _deviceRegistrationComplete = false;

  Future<AuthResponse> login(LoginRequest request) async {
    final AuthTokenResponse response;
    try {
      response = await _client.post(
        APIEndpoint.authLogin,
        (json) => AuthTokenResponse.fromJson(json as Map<String, dynamic>),
        data: request.toJson(),
        authenticated: false,
        headers: featureHeaders,
      );
    } on APIException catch (error) {
      final challenge = mfaChallengeOf(error, request.email);
      if (challenge != null) throw MfaRequiredException(challenge);
      rethrow;
    }
    return _completeNativeSession(response, request.email, sendCode: true);
  }

  /// The second sign-in step. [code] is the six-digit code or a recovery
  /// code; the answer is the same as a normal sign-in.
  Future<AuthResponse> loginMfa(MfaChallenge challenge, String code) async {
    final response = await _client.post(
      APIEndpoint.authLoginMfa,
      (json) => AuthTokenResponse.fromJson(json as Map<String, dynamic>),
      data: {'mfa_token': challenge.token, 'code': code},
      authenticated: false,
      headers: featureHeaders,
    );
    return _completeNativeSession(response, challenge.email, sendCode: true);
  }

  /// The challenge in a `403 MFA_REQUIRED` answer, or null for any other
  /// error (also when the token is missing).
  static MfaChallenge? mfaChallengeOf(APIException error, String email) {
    if (error.code != APIErrorCode.mfaRequired) return null;
    final token = error.details?['mfa_token'];
    if (token is! String || token.isEmpty) return null;
    final seconds = error.details?['mfa_expires_in'];
    final ttl = seconds is num && seconds > 0 ? seconds.toInt() : 300;
    return MfaChallenge(
      token: token,
      email: email.trim(),
      expiresAt: DateTime.now().add(Duration(seconds: ttl)),
    );
  }

  Future<AuthResponse> register(RegisterRequest request) async {
    final response = await _client.post(
      APIEndpoint.authRegister,
      (json) => AuthTokenResponse.fromJson(json as Map<String, dynamic>),
      data: {...request.toJson(), 'locale': ColituLoc.I.language},
      authenticated: false,
    );
    // A new account on the same installation must not inherit the device
    // identity that was bound to a previous account.
    await DeviceIdentityService(tokenStore: _tokenStore).rotateDeviceKey();
    // Registration already e-mails the first code when verification is on.
    return _completeNativeSession(response, request.email, sendCode: false);
  }

  /// E-mails a six-digit password reset code. Unknown addresses get the
  /// same answer, so the form cannot tell who has an account.
  Future<void> requestPasswordReset(String email) async {
    await _client.post(
      APIEndpoint.passwordForgot,
      (_) => null,
      data: {'email': email.trim(), 'locale': ColituLoc.I.language},
      authenticated: false,
    );
  }

  /// Sets a new password with the e-mailed code. The panel ends every other
  /// session and signs this device in.
  Future<AuthResponse> resetPassword(String email, String code, String password) async {
    final response = await _client.post(
      APIEndpoint.passwordReset,
      (json) => AuthTokenResponse.fromJson(json as Map<String, dynamic>),
      data: {'email': email.trim(), 'code': code, 'password': password},
      authenticated: false,
      headers: featureHeaders,
    );
    return _completeNativeSession(response, email.trim(), sendCode: true);
  }

  /// The TV (or other device) waiting for this account's approval.
  Future<LinkRequest> lookupLink(String code) {
    return _client.postRenewing(
      APIEndpoint.linkLookup,
      (json) => LinkRequest.fromJson(json as Map<String, dynamic>),
      data: () => {'code': code},
    );
  }

  /// Approves (signs the waiting device in to this account) or declines.
  Future<void> decideLink(String code, {required bool approve}) async {
    await _client.postRenewing(
      approve ? APIEndpoint.linkApprove : APIEndpoint.linkDeny,
      (_) => null,
      data: () => {'code': code},
    );
  }

  /// E-mails a new six-digit code (the panel allows one a minute).
  Future<void> sendVerificationCode() async {
    await _client.postRenewing(
      APIEndpoint.emailSend,
      (_) => null,
      data: () => {'locale': ColituLoc.I.language},
    );
  }

  /// Confirms the code, then finishes what sign-in could not do: registers
  /// this device (the trial starts now) and loads the account.
  Future<ColituUser> verifyEmail(String code) async {
    await _client.postRenewing(
      APIEndpoint.emailVerify,
      (_) => null,
      data: () => {'code': code},
    );
    await _tokenStore.savePendingVerificationEmail(null);
    _deviceRegistrationComplete = false;
    await ensureDeviceRegistration();
    final user = await _client.get(
      APIEndpoint.me,
      (json) => ColituUser.fromJson(json as Map<String, dynamic>),
    );
    final tokens = await _tokenStore.readTokens();
    if (tokens != null) await _tokenStore.saveTokens(tokens, userId: user.id);
    return user;
  }

  Future<void> logout() async {
    try {
      // A refresh still running would rotate the token sent below: wait for
      // it, so the token the panel revokes is the newest one.
      await _client.settleRefresh();
      // Send the refresh token so the backend can revoke the session
      // server-side; otherwise it stays valid until its TTL expires.
      final tokens = await _tokenStore.readTokens();
      final refreshToken = tokens?.refreshToken;
      // Unauthenticated (the panel only needs the refresh token): an expired
      // access token must not start yet another refresh here.
      await _client.post(
        APIEndpoint.authLogout,
        (_) => null,
        data: refreshToken == null || refreshToken.isEmpty
            ? const <String, dynamic>{}
            : <String, dynamic>{'refresh_token': refreshToken},
        authenticated: false,
      );
    } catch (_) {
      // Logout is best-effort; local credentials must still be removed.
    }
    await _tokenStore.clear();
    _deviceRegistrationComplete = false;
  }

  /// Refreshes the server-side device record after an app update as well as
  /// after a new sign-in. This keeps config formats and supported transports
  /// in sync without requiring the user to sign out and back in.
  Future<void> ensureDeviceRegistration() async {
    if (_deviceRegistrationComplete) return;
    final inFlight = _deviceRegistrationInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final operation = _registerCurrentDevice();
    _deviceRegistrationInFlight = operation;
    try {
      await operation;
      _deviceRegistrationComplete = true;
    } finally {
      if (identical(_deviceRegistrationInFlight, operation)) {
        _deviceRegistrationInFlight = null;
      }
    }
  }

  Future<String> _registerCurrentDevice() async {
    final identity = DeviceIdentityService(tokenStore: _tokenStore);
    final package = await PackageInfo.fromPlatform();
    final device = await _client.post(
      APIEndpoint.registerDevice,
      (json) => json as Map<String, dynamic>,
      data: {
        'device_key': await identity.deviceKey(),
        'name': await _deviceName(),
        'platform': Platform.operatingSystem,
        // Keep the build number in the device record so production logs can
        // distinguish TestFlight binaries that share the same marketing
        // version. The server's semantic version parser intentionally ignores
        // the +build suffix for update policy checks.
        'app_version': '${package.version}+${package.buildNumber}',
        'os_version': Platform.operatingSystemVersion,
        'hardware_id': ?await _hardwareId(),
        'capabilities': {
          'config_formats': ['xray-mobile-v1'],
          'protocols': [
            'vless-reality',
            'vless-xhttp',
            'hysteria2',
            'trojan',
            'shadowsocks',
          ],
        },
      },
    );
    final deviceId = '${device['id'] ?? ''}';
    if (deviceId.isEmpty) {
      throw const FormatException('Device response is missing id');
    }
    await _tokenStore.saveDeviceId(deviceId);
    return deviceId;
  }

  /// A hash of the vendor identifier, which survives app reinstalls while any
  /// app of the vendor stays installed. The panel only uses it to stop the
  /// free trial being claimed again from the same device.
  Future<String?> _hardwareId() async {
    try {
      String? raw;
      if (Platform.isIOS) {
        raw = (await DeviceInfoPlugin().iosInfo).identifierForVendor;
      } else if (Platform.isMacOS) {
        raw = (await DeviceInfoPlugin().macOsInfo).systemGUID;
      }
      if (raw == null || raw.isEmpty) return null;
      final digest = sha256.convert(utf8.encode('colitu-hardware-v1|$raw'));
      return '${Platform.operatingSystem}-$digest';
    } catch (_) {
      return null;
    }
  }

  /// The name shown in the account's device list on every platform
  /// ("iPhone 15 Pro", "Ayşe’s iPad"), never a bare "ios device".
  Future<String> _deviceName() async {
    try {
      if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        final userName = info.name.trim();
        if (userName.isNotEmpty && userName.toLowerCase() != 'iphone') {
          return userName;
        }
        final model = info.utsname.machine.trim();
        return model.isEmpty ? 'iPhone' : _marketingName(model);
      }
      if (Platform.isMacOS) {
        final info = await DeviceInfoPlugin().macOsInfo;
        return info.computerName.trim().isEmpty ? 'Mac' : info.computerName;
      }
    } catch (_) {
      // Fall through to the generic name.
    }
    return '${Platform.operatingSystem} device';
  }

  static String _marketingName(String machine) {
    if (machine.startsWith('iPad')) return 'iPad';
    if (machine.startsWith('iPhone')) return 'iPhone';
    return machine;
  }

  Future<AuthResponse> _completeNativeSession(
    AuthTokenResponse response,
    String email, {
    required bool sendCode,
  }) async {
    _deviceRegistrationComplete = false;
    // Refreshes still running for a previous session must not touch this one.
    _tokenStore.beginSession();
    await _tokenStore.saveTokens(response.tokens);
    await _tokenStore.savePendingVerificationEmail(null);
    try {
      await ensureDeviceRegistration();
      final user = await _client.get(
        APIEndpoint.me,
        (json) => ColituUser.fromJson(json as Map<String, dynamic>),
      );
      // The current tokens, not the ones from sign-in: /me may have refreshed
      // them, and writing back the used refresh token would end the session
      // on the next refresh (the panel treats it as reuse).
      final current = await _tokenStore.readTokens() ?? response.tokens;
      await _tokenStore.saveTokens(current, userId: user.id);
      return AuthResponse(tokens: current, user: user);
    } on APIException catch (error) {
      if (error.code == APIErrorCode.emailNotVerified) {
        // Keep the tokens: the verification endpoints only need the account.
        await _tokenStore.savePendingVerificationEmail(email);
        if (sendCode) {
          try {
            await sendVerificationCode();
          } catch (_) {
            // A code sent less than a minute ago is still valid; the code
            // screen offers "send again" for anything else.
          }
        }
        rethrow;
      }
      await _tokenStore.clear();
      rethrow;
    } catch (_) {
      await _tokenStore.clear();
      rethrow;
    }
  }
}
