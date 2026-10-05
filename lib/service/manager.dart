import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:colitu_vpn/core/network/client.dart';
import 'package:colitu_vpn/colitu/services/network_transition_service.dart';
import 'package:colitu_vpn/service/background_task/service.dart';
import 'package:colitu_vpn/service/menu/short_cut/service.dart';
import 'package:colitu_vpn/service/menu/tray/service.dart';
import 'package:colitu_vpn/service/menu/window/service.dart';
import 'package:colitu_vpn/service/notification/service.dart';
import 'package:colitu_vpn/service/share/service.dart';
import 'package:colitu_vpn/service/toast/service.dart';
import 'package:colitu_vpn/service/vpn/service.dart';

abstract final class ServiceManager {
  static Future<void> serviceInit(BuildContext context) async {
    await _initStep('Network client', () => NetClient().asyncInit());
    await _initStep('Tray service', () async => TrayService().init());
    await _initStep('VPN service', () => VpnService().asyncInit());
    await _initStep('Share service', () async => ShareService().init());
    await _initStep(
      'Notification service',
      () => NotificationService().asyncInit(),
    );
    if (context.mounted) {
      await _initStep(
        'Shortcut service',
        () => ShortCutService().asyncInit(context),
      );
    }
    await _initStep('Window service', () => WindowService().asyncInit());
    await _initStep(
      'Background task service',
      () => BackgroundTaskService().asyncInit(),
    );
    await _initStep(
      'Network transition service',
      () => NetworkTransitionService().asyncInit(),
    );
    await _initStep('Toast service', () async => ToastService().init());
  }

  static void serviceDispose() {
    TrayService().dispose();
    VpnService().dispose();
    ShareService().dispose();
    NotificationService().dispose();
    ShortCutService().dispose();
    WindowService().dispose();
    BackgroundTaskService().dispose();
    NetworkTransitionService().dispose();
    ToastService().dispose();
  }

  static Future<void> _initStep(
    String label,
    FutureOr<void> Function() action,
  ) async {
    try {
      await Future.sync(action).timeout(const Duration(seconds: 10));
      debugPrint('$label initialized');
    } catch (error, stack) {
      debugPrint('$label init failed: $error');
      debugPrint('$stack');
    }
  }
}
