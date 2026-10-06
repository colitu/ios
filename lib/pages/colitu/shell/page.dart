import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/paused/page.dart';
import 'package:colitu_vpn/pages/colitu/shell/account_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/locations_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/plan_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/support_tab.dart';
import 'package:colitu_vpn/pages/colitu/split_tunnel/page.dart';
import 'package:colitu_vpn/pages/main/url.dart';

enum ColituTab { home, locations, plan, support, account }

/// Signed-in shell: floating pill navigation over four pages (home,
/// locations, plan, account with settings) sharing one connection
/// controller.
class ColituShellPage extends StatefulWidget {
  const ColituShellPage({super.key, this.initialTab = ColituTab.home});

  final ColituTab initialTab;

  @override
  State<ColituShellPage> createState() => _ColituShellPageState();
}

class _ColituShellPageState extends State<ColituShellPage> {
  final _controller = ColituConnectionController();
  late ColituTab _tab = widget.initialTab;
  String? _shownNotice;
  var _sessionEnded = false;

  /// The account tab opens scrolled to the privacy mode switch.
  var _focusPrivacy = false;

  @override
  void initState() {
    super.initState();
    _controller.onSessionEnded = _onSessionEnded;
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.init());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSessionEnded() {
    if (_sessionEnded || !mounted) return;
    _sessionEnded = true;
    context.go(RouterPath.colituAuth, extra: ColituLoc.I['auth.expired']);
  }

  void _onControllerChanged() {
    final notice = _controller.notice;
    if (notice != null && notice != _shownNotice && mounted) {
      _shownNotice = notice;
      showColituToast(context, notice);
    }
    if (notice == null) _shownNotice = null;
    if (_controller.ruDirectNoticePending &&
        mounted &&
        _controller.takeRuDirectNotice()) {
      unawaited(_showRuDirectNotice());
    }
  }

  /// One-time explanation, the first time a connection sends Russian
  /// addresses outside the tunnel.
  Future<void> _showRuDirectNotice() async {
    final loc = ColituLoc.I;
    final enable = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(loc['privacy.notice.title']),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Text(loc['privacy.notice.body']),
            CupertinoButton(
              padding: const EdgeInsets.only(top: 8),
              onPressed: () => launchUrl(
                Uri.parse(ColituRuBypass.docsUrl(loc.language)),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(loc['privacy.details']),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(loc['privacy.notice.keep']),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(loc['privacy.notice.enable']),
          ),
        ],
      ),
    );
    if (enable == true) await _controller.setPrivacyMode(true);
  }

  void _select(ColituTab tab, {bool focusPrivacy = false}) {
    if (_tab == tab) return;
    _controller.supportOpen = tab == ColituTab.support;
    setState(() {
      _tab = tab;
      _focusPrivacy = focusPrivacy;
    });
  }

  Future<void> _toggleConnection() async {
    try {
      await _controller.toggle();
    } on ColituPlanRequiredException {
      if (!mounted) return;
      _select(ColituTab.plan);
      showColituToast(context, ColituLoc.I['err.noPlan'], error: true);
    }
  }

  Future<void> _signOut({bool confirm = true}) async {
    final loc = ColituLoc.I;
    final confirmed = !confirm ||
        await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(loc['account.signOut']),
        content: Text(loc['account.signOutConfirm']),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(loc['pay.cancel']),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(loc['account.signOut']),
          ),
        ],
      ),
    ) == true;
    if (!confirmed || !mounted) return;
    _sessionEnded = true;
    try {
      await _controller.signOut();
    } catch (error) {
      // The local session is gone either way; never leave the user in the
      // shell of an account that is signed out.
      debugPrint('Sign-out failed: $error');
    } finally {
      if (mounted) context.go(RouterPath.colituAuth);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The language singleton is merged in so switching the language
      // rebuilds every tab immediately.
      listenable: Listenable.merge([_controller, ColituLoc.I]),
      builder: (context, _) {
        final loc = ColituLoc.I;
        final items = [
          ColituNavItem(icon: CupertinoIcons.house_fill, label: loc['nav.home']),
          ColituNavItem(icon: CupertinoIcons.globe, label: loc['nav.locations']),
          ColituNavItem(icon: CupertinoIcons.gift_fill, label: loc['nav.plan']),
          ColituNavItem(
            icon: CupertinoIcons.chat_bubble_text_fill,
            label: loc['nav.support'],
            badge: _controller.supportUnread,
          ),
          ColituNavItem(icon: CupertinoIcons.person_fill, label: loc['nav.account']),
        ];
        final Widget body = switch (_tab) {
          // A paused device (over the plan's device limit) cannot connect:
          // the home tab explains why and offers the way out.
          ColituTab.home when _controller.paused != null => ColituPausedView(
            controller: _controller,
          ),
          ColituTab.home => HomeTab(
            controller: _controller,
            onToggle: _toggleConnection,
            onChangeLocation: () => _select(ColituTab.locations),
            onOpenPlan: () => _select(ColituTab.plan),
            onOpenPrivacy: () =>
                _select(ColituTab.account, focusPrivacy: true),
            onOpenSplitTunnel: () =>
                ColituSplitTunnelPage.open(context, _controller),
          ),
          ColituTab.locations => LocationsTab(
            controller: _controller,
            onOpenPlan: () => _select(ColituTab.plan),
          ),
          ColituTab.plan => PlanTab(controller: _controller),
          ColituTab.support => SupportTab(controller: _controller),
          ColituTab.account => AccountTab(
            controller: _controller,
            onOpenPlan: () => _select(ColituTab.plan),
            onOpenSupport: () => _select(ColituTab.support),
            onSignOut: _signOut,
            onSessionEnded: () => _signOut(confirm: false),
            focusPrivacy: _focusPrivacy,
          ),
        };
        return ColituScaffold(
          padding: EdgeInsets.zero,
          safeBottom: false,
          bottomNavigationBar: ColituNavBar(
            items: items,
            index: _tab.index,
            onChanged: (index) => _select(ColituTab.values[index]),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.02),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(key: ValueKey(_tab), child: body),
          ),
        );
      },
    );
  }
}

/// Shared scroll container for the tabs: page padding plus room for the
/// floating nav bar.
class ShellScroll extends StatelessWidget {
  const ShellScroll({super.key, required this.children, this.onRefresh});

  final List<Widget> children;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        116 + MediaQuery.paddingOf(context).bottom,
      ),
      children: children,
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(
      onRefresh: onRefresh!,
      color: ColituColors.lilac,
      backgroundColor: ColituColors.navy,
      child: list,
    );
  }
}
