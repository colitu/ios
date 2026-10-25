import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_client.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_reveal.dart';

/// Runs Colitu Passport inside the signed-in shell (Android ColituApp.kt +
/// PassportRevealHost). The passport lives on the account: this refreshes the
/// cached copy on start, on every return to the foreground and after a
/// connect, remembers the city under each stamp and plays the server's new
/// events one after another, then acks them.
class PassportHost extends StatefulWidget {
  const PassportHost({super.key, required this.controller, required this.child, this.client});

  final ColituConnectionController controller;
  final Widget child;

  /// Tests pass their own; defaults to [PassportClient.I].
  final PassportClient? client;

  @override
  State<PassportHost> createState() => _PassportHostState();
}

class _PassportHostState extends State<PassportHost> with WidgetsBindingObserver {
  final _queue = <PassportReveal>[];
  Timer? _poll;
  var _showing = false;
  var _foreground = true;
  var _wasConnected = false;

  ColituConnectionController get c => widget.controller;

  PassportClient get _client => widget.client ?? PassportClient.I;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_onController);
    _wasConnected = c.connected;
    unawaited(_refresh());
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
    final back = state == AppLifecycleState.resumed && !_foreground;
    _foreground = state == AppLifecycleState.resumed;
    // Back in the foreground: what the account earned meanwhile plays now.
    if (back) unawaited(_refresh());
  }

  void _onController() {
    final server = c.connectedServer;
    if (c.connected && server != null) {
      ColituPassport.I.rememberCity(server.countryCode, server.city);
    }
    if (c.connected && !_wasConnected) unawaited(_refresh());
    _wasConnected = c.connected;
  }

  Future<void> _refresh() async {
    await _client.refresh();
    _tick();
  }

  void _tick() {
    if (!mounted || !_foreground || _showing) return;
    _queue.addAll(_client.takeReveals());
    if (_queue.isEmpty) return;
    unawaited(_showNext());
  }

  /// Plays the queued reveals in order; acks once the queue is empty.
  /// Something taken away plays nothing: one short notice for the batch.
  Future<void> _showNext() async {
    _showing = true;
    var shown = 0;
    var revoked = false;
    try {
      while (_queue.isNotEmpty && mounted) {
        final reveal = _queue.removeAt(0);
        final event = reveal.event;
        if (event != null) await showPassportReward(context, event, premium: c.planActive);
        revoked |= reveal.revoked;
        shown = reveal.id;
        ColituPassport.I.reload();
      }
    } finally {
      _showing = false;
      if (shown > 0) unawaited(_client.ack(shown));
      if (revoked && mounted) showColituToast(context, ColituLoc.I['passport.updated']);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
