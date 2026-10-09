import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/pages/main/url.dart';

/// Startup gate: restores the saved session and routes to the shell, to the
/// first-launch tour or to sign-in. A stored session keeps the user signed in
/// even when the panel is unreachable; only a terminal auth failure sends
/// them back to sign-in.
class ColituGatePage extends StatefulWidget {
  const ColituGatePage({super.key});

  @override
  State<ColituGatePage> createState() => _ColituGatePageState();
}

class _ColituGatePageState extends State<ColituGatePage> {
  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    try {
      await _routeOnce();
    } catch (error) {
      // A Keychain or preferences error must not leave the spinner up forever.
      debugPrint('Startup routing failed: $error');
      if (mounted) context.go(RouterPath.colituAuth);
    }
  }

  Future<void> _routeOnce() async {
    // First thing: the privacy mode default depends on what an earlier
    // version left behind, before this start writes anything itself.
    try {
      await PreferencesKey().resolveColituPrivacyDefault(
        hasSession: () async => await SecureTokenStore().readTokens() != null,
      );
    } catch (error) {
      debugPrint('Privacy default failed: $error');
    }
    await ColituLoc.I.load();
    if (await SecureTokenStore().readTokens() != null &&
        await AppSession.instance.pendingVerificationEmail() != null) {
      if (mounted) context.go(RouterPath.colituVerify);
      return;
    }
    // With a stored session the shell opens on it anyway when the panel
    // does not answer: wait briefly, or a tunnel that is up but passes no
    // traffic keeps the user on this spinner, unable to reach the
    // disconnect button.
    final hasSession = await SecureTokenStore().readTokens() != null;
    try {
      final state = await AppSession.instance.bootstrap().timeout(
        Duration(seconds: hasSession ? 5 : 12),
      );
      if (!mounted) return;
      switch (state.authState) {
        case ColituAuthState.unauthenticated:
          await _goSignedOut(null);
        case ColituAuthState.authenticatedNoSubscription:
        case ColituAuthState.authenticatedActiveSubscription:
          context.go(RouterPath.home);
        case ColituAuthState.error:
          await _goHomeIfSessionExists(state.errorMessage);
        case ColituAuthState.loading:
          break;
      }
    } catch (error, stack) {
      debugPrint('Auth bootstrap failed: $error');
      debugPrint('$stack');
      await _goHomeIfSessionExists(null);
    }
  }

  Future<void> _goHomeIfSessionExists(String? message) async {
    final hasSession = await SecureTokenStore().readTokens() != null;
    if (!mounted) return;
    if (hasSession) {
      context.go(RouterPath.home);
    } else {
      await _goSignedOut(message);
    }
  }

  /// New installs see the tour first; everyone else goes to sign-in.
  Future<void> _goSignedOut(String? message) async {
    final seen = await PreferencesKey().readColituOnboardingSeen();
    if (!mounted) return;
    if (!seen && message == null) {
      context.go(RouterPath.colituOnboarding);
    } else {
      context.go(RouterPath.colituAuth, extra: message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ColituLoc.I,
      builder: (context, _) => ColituScaffold(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ColituWordmark(height: 22),
              const SizedBox(height: 28),
              const ColituSpinner(),
              const SizedBox(height: 16),
              Text(ColituLoc.I['loading.session'], style: ColituText.muted),
            ],
          ),
        ),
      ),
    );
  }
}
