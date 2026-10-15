import 'package:flutter/services.dart';

/// Keeps a directory out of iCloud and computer backups (iOS
/// `isExcludedFromBackup`, set by AppDelegate.swift on the `colitu/backup`
/// channel). Server credentials live in the database and in the tunnel's
/// run directory; the Keychain already keeps its copies on this device only.
///
/// Best effort: without the channel (tests, a background isolate, another
/// platform) nothing happens and nothing is thrown.
abstract final class ColituBackupExclusion {
  static const _channel = MethodChannel('colitu/backup');

  static Future<bool> exclude(String path) async {
    try {
      return await _channel.invokeMethod<bool>('excludeFromBackup', path) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
