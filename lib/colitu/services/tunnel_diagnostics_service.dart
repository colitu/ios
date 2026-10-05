import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:colitu_vpn/colitu/services/diagnostic_info_service.dart';
import 'package:colitu_vpn/colitu/services/log_redaction.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:colitu_vpn/core/tools/file.dart';
import 'package:colitu_vpn/service/xray/constants.dart';

/// Collects what the packet-tunnel extension recorded (stops, stability
/// events, crash output, core errors) into one text file the user can send
/// to support. The extension has no console: this is the only way to see
/// why a tunnel dropped on a device.
class TunnelDiagnosticsService {
  /// Builds the report text. [runDir] defaults to the shared run directory.
  Future<String> buildReport({String? runDir}) async {
    final dir = runDir ?? VpnConstants.runDir;
    final sections = <String>[
      await DiagnosticInfoService().buildSupportDiagnostics(),
      'Report time: ${DateTime.now().toIso8601String()}',
      await _section('Tunnel stops (drops.jsonl)', p.join(dir, 'drops.jsonl')),
      await _section('Last heartbeat (traffic.json)', p.join(dir, 'traffic.json')),
      await _section(
        'Extension stderr, current run',
        p.join(dir, 'tunnel-stderr.log'),
        maxBytes: 64 << 10,
      ),
      await _section(
        'Extension stderr, previous run',
        p.join(dir, 'tunnel-stderr.prev.log'),
        maxBytes: 64 << 10,
      ),
      await _section(
        'Stability events, earlier sessions (stability_log.prev.jsonl)',
        p.join(dir, 'stability_log.prev.jsonl'),
        maxBytes: 192 << 10,
      ),
      await _section(
        'Stability events, current session (stability_log.jsonl)',
        p.join(dir, 'stability_log.jsonl'),
        maxBytes: 160 << 10,
      ),
      await _section(
        'Core error log, earlier sessions',
        p.join(dir, 'error.prev.log'),
        maxBytes: 32 << 10,
      ),
      await _section(
        'Core error log, current session',
        p.join(dir, XrayStateConstants.errorLog),
        maxBytes: 48 << 10,
      ),
    ];
    return sections.join('\n\n');
  }

  /// Writes the report to a temporary file and opens the share sheet.
  Future<bool> share({Rect? origin}) async {
    final report = await buildReport();
    final cacheDir = await FileTool.makeCacheDir();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
    final name = 'colitu-diagnostics-$stamp.txt';
    final path = p.join(cacheDir, name);
    await File(path).writeAsString(report);
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'text/plain')],
          fileNameOverrides: [name],
          sharePositionOrigin: origin,
        ),
      );
      return result.status != ShareResultStatus.unavailable;
    } finally {
      await FileTool.deleteDirIfExists(cacheDir);
    }
  }

  /// One titled section with the end of [path] (the newest records).
  Future<String> _section(String title, String path, {int maxBytes = 32 << 10}) async {
    final header = '===== $title =====';
    final file = File(path);
    try {
      if (!await file.exists()) return '$header\n(none)';
      final length = await file.length();
      final start = math.max(0, length - maxBytes);
      final raf = await file.open();
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(length - start);
        var text = utf8.decode(bytes, allowMalformed: true);
        if (start > 0) {
          // Drop the partial first line of a tail.
          final newline = text.indexOf('\n');
          text = '(… ${start >> 10} KB earlier omitted)\n${newline >= 0 ? text.substring(newline + 1) : text}';
        }
        // The report can be shared anywhere: no credentials or e-mails in it.
        return '$header\n${text.trim().isEmpty ? '(empty)' : LogRedaction.redact(text.trimRight())}';
      } finally {
        await raf.close();
      }
    } catch (e) {
      return '$header\n(unreadable: $e)';
    }
  }
}
