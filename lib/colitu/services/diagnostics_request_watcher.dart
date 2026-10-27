import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:colitu_vpn/colitu/services/support_service.dart';

/// Asks the panel, when signed in, whether a support agent wants this
/// device's connection report, and sends it silently (no dialog). After a
/// send, [onSent] runs once so the app can show one short notice.
///
/// Checked on start and whenever the app returns to the foreground, at most
/// once per [minInterval]. A request answered in this run (also one the
/// panel no longer knows) is not sent again; any other failure is retried at
/// the next check, but not sooner than [retryAfter].
class DiagnosticsRequestWatcher with WidgetsBindingObserver {
  DiagnosticsRequestWatcher({
    required this.api,
    required this.buildReport,
    this.onSent,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const minInterval = Duration(seconds: 60);
  static const retryAfter = Duration(minutes: 10);

  final ColituSupportService api;
  final Future<String> Function() buildReport;

  /// Called once after the report was sent (not for a failure).
  final void Function()? onSent;
  final DateTime Function() _clock;

  DateTime? _lastCheck;
  DateTime? _retryAfter;
  final _answered = <String>{};
  var _busy = false;
  var _disposed = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(check());
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  Future<void> check() async {
    if (_busy || _disposed) return;
    final now = _clock();
    final last = _lastCheck;
    if (last != null && now.difference(last) < minInterval) return;
    _lastCheck = now;
    _busy = true;
    try {
      final request = await api.pendingDiagnosticsRequest();
      if (request == null || _disposed || _answered.contains(request.id)) return;
      final retry = _retryAfter;
      if (retry != null && _clock().isBefore(retry)) return;
      try {
        await api.answerDiagnosticsRequest(request.id, await buildReport());
        _answered.add(request.id);
        _retryAfter = null;
        if (!_disposed) {
          try {
            onSent?.call();
          } catch (_) {}
        }
      } catch (_) {
        _retryAfter = _clock().add(retryAfter);
      }
    } catch (_) {
      // Best effort: support may be switched off or the network is gone.
    } finally {
      _busy = false;
    }
  }
}
