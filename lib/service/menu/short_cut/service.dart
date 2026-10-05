import 'package:flutter/material.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:colitu_vpn/core/tools/platform.dart';

/// Home-screen quick actions. Colitu offers none: the upstream "Start VPN"
/// action started whatever configuration was first in the local database,
/// past sign-in, the plan check and Colitu's own connection flow. Earlier
/// versions registered the actions, so they are removed here.
final class ShortCutService {
  static final ShortCutService _singleton = ShortCutService._internal();

  factory ShortCutService() => _singleton;

  ShortCutService._internal();

  final quickActions = const QuickActions();

  Future<void> asyncInit(BuildContext context) async {
    if (!AppPlatform.isMobile) {
      return;
    }
    await quickActions.clearShortcutItems();
  }

  void dispose() {}
}
