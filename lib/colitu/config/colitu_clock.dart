import 'package:flutter/foundation.dart';

/// "Now" for plan dates and banners. Tests fix it so screenshots and day
/// counts do not change with the calendar.
abstract final class ColituClock {
  static DateTime Function() _now = DateTime.now;

  static DateTime now() => _now();

  /// Replaces the clock; null restores the real one.
  @visibleForTesting
  static void fix(DateTime Function()? now) => _now = now ?? DateTime.now;
}
