import 'dart:io';

import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/log_redaction.dart';
import 'package:colitu_vpn/colitu/services/server_latency.dart';
import 'package:colitu_vpn/service/xray/raw/fix.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the fixes of the 2026-10 security audit.
void main() {
  test('diagnostics hide credentials, tokens and e-mails', () {
    const log = 'GET https://api.example.com/x?token=tok123&lang=en\n'
        'vless://0f5c2d9e-uuid@pro.example.org:8443?pbk=pbk456&sid=sid789\n'
        'account mail@example.com signed in\n'
        'proxy http://user:pa55@10.0.0.1:8080\n'
        'vmess://eyJ2IjoiMiIsImlkIjoic2VjcmV0LXV1aWQifQ==\n'
        'Authorization: Bearer abc.def.ghi\n'
        'token eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.c2lnbmF0dXJl\n'
        '{"id":"0b2c-uuid","password":"hunter2","server":"pro.example.org"}';

    final redacted = LogRedaction.redact(log);

    for (final secret in [
      'tok123',
      '0f5c2d9e',
      'pbk456',
      'sid789',
      'mail@',
      'pa55',
      'c2VjcmV0LXV1aWQ',
      'abc.def.ghi',
      'eyJzdWIiOiJ1c2VyIn0',
      '0b2c-uuid',
      'hunter2',
    ]) {
      expect(redacted, isNot(contains(secret)), reason: secret);
    }
    // The server stays readable: support needs it.
    expect(redacted, contains('vless://***@pro.example.org:8443'));
    expect(redacted, contains('lang=en'));
    expect(redacted, contains('"server":"pro.example.org"'));
  });

  test('pings never dial loopback, private or link-local addresses', () {
    bool public(String address) => ServerLatency.isPublic(InternetAddress(address));

    expect(public('203.0.113.7'), isTrue);
    expect(public('8.8.8.8'), isTrue);
    expect(public('2a00:1450:4001::1'), isTrue);
    for (final address in [
      '127.0.0.1',
      '10.1.2.3',
      '172.20.0.1',
      '192.168.1.1',
      '100.64.0.1',
      '169.254.1.1',
      '0.0.0.0',
      '224.0.0.1',
      '::1',
      'fd00::1',
      'fe80::1',
      '::ffff:192.168.1.1',
    ]) {
      expect(public(address), isFalse, reason: address);
    }
  });

  group('Russian sites', () {
    tearDown(() => ColituRuBypass.serverCountry = null);

    Map<String, dynamic> config() => <String, dynamic>{
          'outbounds': <dynamic>[
            <String, dynamic>{'tag': 'proxy', 'protocol': 'vless'},
          ],
          'routing': <String, dynamic>{'rules': <dynamic>[]},
        };

    bool hasBypass(Map<String, dynamic> json) =>
        ((json['routing'] as Map)['rules'] as List).any((rule) => rule is Map && (rule['ip'] as List?)?.contains('geoip:RU') == true);

    test('leave the tunnel directly on a server outside Russia', () {
      ColituRuBypass.serverCountry = 'DE';
      final json = config();
      XrayRawFix.fixRussianIpBypass(json);
      expect(hasBypass(json), isTrue);
    });

    test('go through the tunnel when the server is in Russia', () {
      ColituRuBypass.serverCountry = 'ru';
      final json = config();
      XrayRawFix.fixRussianIpBypass(json);
      expect(hasBypass(json), isFalse);
    });
  });
}
