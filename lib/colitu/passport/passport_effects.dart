import 'package:flutter/services.dart';

import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';

/// Sound and haptics of the passport rewards, each behind its own switch.
/// Sounds play through an ambient audio session (AppDelegate
/// "colitu/passport_sound"): quiet when the phone is on silent, mixed with
/// whatever else plays. Never throws.
abstract final class PassportEffects {
  static const _channel = MethodChannel('colitu/passport_sound');

  /// `reveal`, `piece`, `level` or `seal` (`assets/passport/sounds/passport_<name>.m4a`).
  static Future<void> sound(String name) async {
    if (!ColituPassport.I.social.sound) return;
    try {
      await _channel.invokeMethod<bool>('play', 'assets/passport/sounds/passport_$name.m4a');
    } catch (_) {
      // No player on this platform (tests, macOS): silence is fine.
    }
  }

  static bool get _on => ColituPassport.I.social.haptics;

  /// A piece lands, a visa stamp drops.
  static void tap() {
    if (_on) HapticFeedback.selectionClick();
  }

  /// A new stamp or level, a card turns.
  static void confirm() {
    if (_on) HapticFeedback.mediumImpact();
  }

  /// A seal hits the page.
  static void thud() {
    if (_on) HapticFeedback.heavyImpact();
  }
}
