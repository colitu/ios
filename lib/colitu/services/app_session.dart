import 'dart:io';

import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/auth_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/subscription_service.dart';
import 'package:colitu_vpn/colitu/services/user_service.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:colitu_vpn/core/tools/logger.dart';
import 'package:colitu_vpn/service/event_bus/service.dart';
import 'package:colitu_vpn/service/vpn/service.dart';

enum ColituAuthState {
  loading,
  unauthenticated,
  authenticatedNoSubscription,
  authenticatedActiveSubscription,
  error,
}

enum ColituConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class ColituAppState {
  final ColituAuthState authState;
  final ColituConnectionState connectionState;
  final ColituUser? user;
  final String? errorMessage;

  const ColituAppState({
    required this.authState,
    required this.connectionState,
    this.user,
    this.errorMessage,
  });

  factory ColituAppState.loading() => const ColituAppState(
    authState: ColituAuthState.loading,
    connectionState: ColituConnectionState.disconnected,
  );
}

class AppSession {
  AppSession({
    SecureTokenStore? tokenStore,
    AuthService? authService,
    UserService? userService,
    ColituSubscriptionService? subscriptionService,
    ColituVPNConfigAdapter? configAdapter,
  }) : _tokenStore = tokenStore ?? SecureTokenStore(),
       _authService = authService ?? AuthService(),
       _userService = userService ?? UserService(),
       _subscriptionService =
           subscriptionService ?? ColituSubscriptionService(),
       _configAdapter = configAdapter ?? ColituVPNConfigAdapter();

  static final AppSession instance = AppSession();

  final SecureTokenStore _tokenStore;
  final AuthService _authService;
  final UserService _userService;
  final ColituSubscriptionService _subscriptionService;
  final ColituVPNConfigAdapter _configAdapter;

  ColituUser? currentUser;

  Future<ColituAppState> bootstrap() async {
    final tokens = await _tokenStore.readTokens();
    if (tokens == null) {
      return const ColituAppState(
        authState: ColituAuthState.unauthenticated,
        connectionState: ColituConnectionState.disconnected,
      );
    }
    return refreshAccount();
  }

  Future<ColituAppState> login(LoginRequest request) async {
    final response = await _authService.login(request);
    currentUser = response.user;
    return refreshAccount();
  }

  Future<ColituAppState> register(RegisterRequest request) async {
    final response = await _authService.register(request);
    currentUser = response.user;
    return refreshAccount();
  }

  Future<void> requestPasswordReset(String email) => _authService.requestPasswordReset(email);

  Future<ColituAppState> resetPassword(String email, String code, String password) async {
    final response = await _authService.resetPassword(email, code, password);
    currentUser = response.user;
    return refreshAccount();
  }

  Future<LinkRequest> lookupLink(String code) => _authService.lookupLink(code);

  Future<void> decideLink(String code, {required bool approve}) => _authService.decideLink(code, approve: approve);

  /// The address the verification code went to, while one is pending.
  Future<String?> pendingVerificationEmail() => _tokenStore.readPendingVerificationEmail();

  Future<void> sendVerificationCode() => _authService.sendVerificationCode();

  Future<ColituAppState> verifyEmail(String code) async {
    currentUser = await _authService.verifyEmail(code);
    return refreshAccount();
  }

  Future<ColituAppState> refreshAccount() async {
    final generation = _tokenStore.sessionGeneration;
    try {
      var user = await _userService.me();
      await _authService.ensureDeviceRegistration();
      try {
        final subscription = await _subscriptionService.subscription();
        user = user.copyWithSubscription(subscription);
      } on APIException catch (error) {
        if (error.code != APIErrorCode.configMissing) {
          rethrow;
        }
      }
      if (generation != _tokenStore.sessionGeneration) {
        // Signed out (or into another account) while the account loaded:
        // never put the previous account back on screen.
        return ColituAppState(
          authState: currentUser == null
              ? ColituAuthState.unauthenticated
              : ColituAuthState.error,
          connectionState: ColituConnectionState.disconnected,
          user: currentUser,
        );
      }
      currentUser = user;
      return ColituAppState(
        authState: user.hasActiveEntitlement
            ? ColituAuthState.authenticatedActiveSubscription
            : ColituAuthState.authenticatedNoSubscription,
        connectionState: ColituConnectionState.disconnected,
        user: user,
      );
    } on APIException catch (error) {
      if (error.terminalAuthFailure &&
          generation == _tokenStore.sessionGeneration) {
        ygLogger(
          "Terminal auth failure: code=${error.code.name} status=${error.statusCode} message=${error.message}",
        );
        await _clearSignedOutSession(reason: error.code.name);
        return const ColituAppState(
          authState: ColituAuthState.unauthenticated,
          connectionState: ColituConnectionState.disconnected,
        );
      }
      final tokens = await _tokenStore.readTokens();
      if (tokens == null) {
        return const ColituAppState(
          authState: ColituAuthState.unauthenticated,
          connectionState: ColituConnectionState.disconnected,
        );
      }
      if (error.code == APIErrorCode.unauthorized ||
          error.code == APIErrorCode.tokenExpired ||
          error.code == APIErrorCode.deviceDisconnected ||
          error.code == APIErrorCode.networkUnavailable ||
          error.code == APIErrorCode.backendUnavailable ||
          error.code == APIErrorCode.serverUnavailable) {
        return ColituAppState(
          authState: ColituAuthState.error,
          connectionState: ColituConnectionState.disconnected,
          user: currentUser,
          errorMessage: error.message,
        );
      }
      return ColituAppState(
        authState: ColituAuthState.error,
        connectionState: ColituConnectionState.disconnected,
        errorMessage: error.message,
      );
    }
  }

  Future<void> logout() async {
    await _stopVpnForSignedOutSession();
    await _authService.logout();
    await _clearLocalSessionState();
  }

  Future<void> _clearSignedOutSession({String reason = "terminal_auth"}) async {
    await _stopVpnForSignedOutSession(reason: reason);
    await _tokenStore.clear();
    await _clearLocalSessionState();
  }

  Future<void> _stopVpnForSignedOutSession({
    String reason = "signed_out",
  }) async {
    try {
      ygLogger("Stopping VPN for signed-out session: reason=$reason");
      await VpnService().forceStopVpnForSignOut().timeout(
        const Duration(seconds: 8),
      );
    } catch (error) {
      ygLogger("VPN force stop during signed-out cleanup failed: $error");
      // Sign-out cleanup must continue even if the VPN engine is already gone.
    }
    await _markVpnDisconnected();
  }

  Future<void> _clearLocalSessionState() async {
    await _configAdapter.clearRuntimeConfig();
    await _deleteTunnelRunFiles();
    currentUser = null;
    await _markVpnDisconnected();
  }

  /// The tunnel reads its start request and core configuration (server
  /// credentials) from the shared container, so turning the VPN on in iOS
  /// Settings after sign-out would connect the previous account. Its logs
  /// and diagnostics go too: they belong to that account.
  Future<void> _deleteTunnelRunFiles() async {
    try {
      final dir = Directory(VpnConstants.runDir);
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File &&
            RegExp(r'\.(json|jsonl|log)$').hasMatch(entity.path)) {
          try {
            await entity.delete();
          } catch (_) {
            // Locked by the extension that is still shutting down.
          }
        }
      }
    } catch (error) {
      ygLogger("Deleting tunnel run files after sign-out failed: $error");
    }
  }

  Future<void> _markVpnDisconnected() async {
    await PreferencesKey().saveRunningConfigId(DBConstants.defaultId);
    await PreferencesKey().saveLastConfigId(DBConstants.defaultId);
    try {
      final eventBus = AppEventBus.instance;
      eventBus.updateVpnLoading(false);
      eventBus.updateRunningId(DBConstants.defaultId);
    } catch (_) {
      // The event bus is not available during a few early startup paths.
    }
  }
}
