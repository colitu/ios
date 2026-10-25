import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:colitu_vpn/core/pigeon/constants.dart';

/// App-side failures worth seeing in a connection report (the extension has
/// its own logs): one line per event in run/app_events.log, newest last,
/// at most [limit] bytes. Never throws.
abstract final class AppEventLog {
  static const fileName = 'app_events.log';
  static const limit = 32 << 10;

  /// Tests write elsewhere.
  @visibleForTesting
  static String? dirOverride;

  static Future<void> add(String event, [Object? error]) async {
    try {
      final dir = dirOverride ?? VpnConstants.runDir;
      await Directory(dir).create(recursive: true);
      final file = File(p.join(dir, fileName));
      final detail = error == null ? '' : ': ${'$error'.replaceAll('\n', ' ')}';
      final line = '${DateTime.now().toUtc().toIso8601String()} $event$detail\n';
      if (await file.exists() && await file.length() > limit) {
        final text = await file.readAsString();
        final tail = text.substring(text.length - limit ~/ 2);
        final newline = tail.indexOf('\n');
        await file.writeAsString(newline >= 0 ? tail.substring(newline + 1) : '', flush: true);
      }
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
