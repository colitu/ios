import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/service/event_bus/service.dart';
import 'package:colitu_vpn/service/vpn/service.dart';

class NetworkTransitionService {
  static final NetworkTransitionService _singleton =
      NetworkTransitionService._internal();

  factory NetworkTransitionService() => _singleton;

  NetworkTransitionService._internal();

  static const _channel = MethodChannel('colitu/network_path');
  static const _debounceDuration = Duration(seconds: 3);
  static const _minimumRenewalGap = Duration(seconds: 20);

  Timer? _debounce;
  DateTime? _lastRenewalAt;
  var _renewing = false;

  Future<void> asyncInit() async {
    // On iOS the tunnel extension follows Wi-Fi/cellular changes itself and
    // restarts only its core, with the routes kept. A full stop and start from
    // here on top of that left traffic outside the tunnel for a few seconds
    // on every network change.
    if (defaultTargetPlatform == TargetPlatform.iOS) return;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  void dispose() {
    _debounce?.cancel();
    _debounce = null;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'networkChanged') return;
    _scheduleRenewal();
  }

  void _scheduleRenewal() {
    _debounce?.cancel();
    _debounce = Timer(
      _debounceDuration,
      () => unawaited(_renewVpnAfterNetworkTransition()),
    );
  }

  Future<void> _renewVpnAfterNetworkTransition() async {
    if (_renewing) return;
    final now = DateTime.now();
    final last = _lastRenewalAt;
    if (last != null && now.difference(last) < _minimumRenewalGap) {
      return;
    }

    final eventBus = AppEventBus.instance;
    if (eventBus.state.runningId == DBConstants.defaultId ||
        eventBus.state.vpnLoading) {
      return;
    }

    _renewing = true;
    _lastRenewalAt = now;
    try {
      await VpnService().restartCurrentVpn();
    } catch (error, stack) {
      debugPrint('Network transition VPN renewal failed: $error');
      debugPrint('$stack');
    } finally {
      _renewing = false;
    }
  }
}
