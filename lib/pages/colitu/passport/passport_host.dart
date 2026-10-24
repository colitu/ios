import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_sync.dart';
import 'package:colitu_vpn/colitu/services/colitu_referral.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_reveal.dart';

/// Runs Colitu Passport inside the signed-in shell (Android ColituApp.kt +
/// PassportRevealHost): counts the minutes the tunnel recorded, tells the
/// tunnel which country the connection counts for, keeps the tester flag
/// and the city, grants the Companion stamp, sends the optional anonymous
/// counters and plays the queued rewards one after another.
class PassportHost extends StatefulWidget {
  const PassportHost({super.key, required this.controller, required this.child});

  final ColituConnectionController controller;
  final Widget child;

  @override
  State<PassportHost> createState() => _PassportHostState();
}

class _PassportHostState extends State<PassportHost> with WidgetsBindingObserver {
  final _queue = <StampEvent>[];
  Timer? _poll;
  var _showing = false;
  var _ticks = 0;
  String? _writtenFor;
  var _companionChecked = false;
  var _foreground = true;

  ColituConnectionController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_onController);
    unawaited(_sync());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    c.removeListener(_onController);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_sync());
  }

  void _onController() {
    final p = ColituPassport.I;
    // Tester accounts see the panel's alpha nodes: a piece every ten minutes.
    final tester = c.servers.any((s) => s.alpha);
    if (p.tester != tester) p.tester = tester;
    final server = c.connectedServer;
    if (c.connected && server != null) {
      p.rememberCity(server.countryCode, server.city);
      final key = '${server.countryCode}|${p.notify}|${p.tester}';
      if (key != _writtenFor) {
        _writtenFor = key;
        unawaited(PassportSync.writeConnection(server.countryCode));
      }
    } else if (!c.connected) {
      _writtenFor = null;
    }
    if (!_companionChecked && c.user != null) {
      _companionChecked = true;
      unawaited(_companionAndMetrics());
    }
  }

  /// Companion stamp for whoever invited someone; anonymous counters once a
  /// day when turned on.
  Future<void> _companionAndMetrics() async {
    final social = ColituPassport.I.social;
    if (!social.companion) {
      try {
        final referral = await ColituReferralService().load();
        if (referral.invited > 0) social.markCompanion();
      } catch (_) {}
    }
    await PassportSync.sendMetrics();
  }

  Future<void> _sync() async {
    await PassportSync.consume();
    _tick();
  }

  void _tick() {
    if (!mounted || !_foreground) return;
    // Every 30 s the minutes the tunnel wrote since; rewards every 2 s.
    if (++_ticks % 15 == 0) unawaited(PassportSync.consume());
    if (_showing) return;
    final p = ColituPassport.I;
    if (_queue.isEmpty) _queue.addAll([...p.takePending(), ...p.goals.checkNew()]);
    if (_queue.isEmpty) return;
    unawaited(_showNext());
  }

  Future<void> _showNext() async {
    _showing = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        final event = _queue.removeAt(0);
        await showPassportReward(context, event, premium: c.planActive);
        ColituPassport.I.reload();
      }
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
