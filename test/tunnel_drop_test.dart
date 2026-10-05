import 'dart:io';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ColituLoc.I.setLanguage('tr', persist: false);
  });

  test('a record left by iOS killing the extension explains the memory cap', () {
    final drop = ColituTunnelDrop.fromJson({
      'ts': DateTime(2026, 9, 25, 3, 7).millisecondsSinceEpoch,
      'kind': 'killed',
      'mem': 49 << 20,
      'peak': 51 << 20,
      'go': 22 << 20,
      'restartedBy': 'ios',
    });
    expect(drop.kind, 'killed');
    expect(drop.restartedByIos, isTrue);
    final text = ColituConnectionController.describeDrop(drop);
    expect(text, contains('03:07'));
    expect(text, contains('51 MB'));
    expect(text, contains('22 MB'));
    expect(text, contains('Sürekli koruma'));
  });

  test('a kill far below the memory cap is not blamed on memory', () {
    final text = ColituConnectionController.describeDrop(
      ColituTunnelDrop.fromJson({
        'ts': DateTime(2026, 9, 25, 5, 46).millisecondsSinceEpoch,
        'kind': 'killed',
        'mem': 27 << 20,
        'peak': 28 << 20,
        'go': 22 << 20,
      }),
    );
    expect(text, contains('haber vermeden'));
    expect(text, contains('28 MB'));
    expect(text, contains('22 MB'));
    expect(text, isNot(contains('bellek sınırı yüzünden')));
  });

  test('a crash report from the extension is shown as a crash', () {
    final drop = ColituTunnelDrop.fromJson({
      'ts': DateTime(2026, 9, 25, 5, 46).millisecondsSinceEpoch,
      'kind': 'crashed',
      'peak': 28 << 20,
      'detail': 'fatal error: concurrent map writes',
      'restartedBy': 'ios',
    });
    expect(drop.detail, 'fatal error: concurrent map writes');
    final text = ColituConnectionController.describeDrop(drop);
    expect(text, contains('VPN motoru çöktü: fatal error: concurrent map writes.'));
    expect(text, contains('Sürekli koruma'));
    expect(
      ColituConnectionController.describeDrop(
        ColituTunnelDrop.fromJson({'ts': 0, 'kind': 'crashed'}),
      ),
      contains('VPN motoru çöktü.'),
    );
  });

  test('stop reasons map to plain explanations', () {
    String describe(String kind) => ColituConnectionController.describeDrop(
      ColituTunnelDrop.fromJson({'ts': 0, 'kind': kind}),
    );
    expect(describe('superceded'), contains('Başka bir VPN'));
    expect(describe('noNetworkAvailable'), contains('Ağ bağlantısı'));
    expect(describe('configurationRemoved'), contains('profili'));
    expect(describe('killed'), contains('haber vermeden'));
    expect(describe('reason99'), contains('reason99'));
  });

  test('bundled geo data is trimmed to the codes the app routes on', () {
    // The packet-tunnel extension has a ~50 MB memory cap; the full
    // v2fly geoip.dat alone is 23 MB.
    expect(File('assets/dat/geoip.dat').lengthSync(), lessThan(2 << 20));
    expect(File('assets/dat/geosite.dat').lengthSync(), lessThan(1 << 20));
  });
}
