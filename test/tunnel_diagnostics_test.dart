import 'dart:io';

import 'package:colitu_vpn/colitu/services/tunnel_diagnostics_service.dart';
import 'package:colitu_vpn/service/vpn/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory runDir;

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Colitu',
      packageName: 'com.colitu.vpn',
      version: '5.2.5',
      buildNumber: '22',
      buildSignature: '',
    );
    runDir = await Directory.systemTemp.createTemp('colitu-run');
  });

  tearDown(() => runDir.delete(recursive: true));

  test('the report holds every tunnel record, newest part of long logs', () async {
    await File(p.join(runDir.path, 'drops.jsonl'))
        .writeAsString('{"kind":"crashed","detail":"fatal error: x"}\n');
    await File(p.join(runDir.path, 'tunnel-stderr.prev.log'))
        .writeAsString('panic: runtime error\n');
    final lines = List.generate(20000, (i) => '{"event":"e$i"}').join('\n');
    await File(p.join(runDir.path, 'stability_log.jsonl')).writeAsString(lines);

    final report = await TunnelDiagnosticsService().buildReport(runDir: runDir.path);

    expect(report, contains('App version: 5.2.5'));
    expect(report, contains('"detail":"fatal error: x"'));
    expect(report, contains('panic: runtime error'));
    expect(report, contains('{"event":"e19999"}'));
    expect(report, isNot(contains('{"event":"e0"}')));
    expect(report, contains('KB earlier omitted'));
    expect(report, contains('===== Core error log, current session =====\n(none)'));
  });

  test('port-hop socket closings are left out of the core errors, real errors stay', () async {
    const noise = '2026/10/24 15:41:16.035457 [Error] transport/internet/finalmask/udphop: '
        'recv err > read udp [::]:65074: use of closed network connection';
    const real = '2026/10/24 15:42:54.536166 [Error] app/dns: failed to resolve';
    await File(p.join(runDir.path, 'error.log')).writeAsString([noise, real, noise].join('\n'));

    final report = await TunnelDiagnosticsService().buildReport(runDir: runDir.path);

    expect(report, isNot(contains('udphop: recv err')));
    expect(report, contains('app/dns: failed to resolve'));
    expect(report, contains('(2 port-hop socket closings left out)'));
    // A fresh report each time: the running app's version and the current time.
    expect(report, contains('Build number: 22'));
    expect(report, contains('Report time: ${DateTime.now().toIso8601String().substring(0, 13)}'));
  });

  test('earlier sessions move to a bounded history instead of being erased', () async {
    final log = p.join(runDir.path, 'stability_log.jsonl');
    final history = p.join(runDir.path, 'stability_log.prev.jsonl');
    for (var session = 0; session < 3; session++) {
      await File(log).writeAsString(
        List.generate(50, (i) => '{"session":$session,"event":"e$i"}\n').join(),
      );
      await VpnService.appendToLogHistory(log, history, maxBytes: 2000);
    }

    expect(await File(log).readAsString(), isEmpty);
    final kept = await File(history).readAsString();
    expect(kept.length, lessThanOrEqualTo(2000));
    expect(kept, startsWith('{"session":'));
    expect(kept, endsWith('{"session":2,"event":"e49"}\n'));
    expect(kept, isNot(contains('"session":0')));

    final report = await TunnelDiagnosticsService().buildReport(runDir: runDir.path);
    expect(report, contains('{"session":2,"event":"e49"}'));
  });
}
