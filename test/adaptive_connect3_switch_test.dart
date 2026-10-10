import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/config/adaptive_connect3.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/recovery_set.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Adaptive Connect 3.0 is off in this release', () {
    expect(kAdaptiveConnect3, isFalse);
  });

  group('hinted start', () {
    ({List<String> order, int hinted})? start({required bool enabled}) =>
        colituHintedStart<String>(
          const ['hysteria2', 'trojan', 'vless-reality'],
          protocolOf: (c) => c,
          preferred: const ['trojan'],
          stalled: const {},
          lastGood: null,
          rank: (rest) => rest,
          enabled: enabled,
        );

    test('on: the preferred protocol goes first', () {
      expect(start(enabled: true)?.order.first, 'trojan');
    });

    test('off: no hinted start, the usual probe and ranking decide', () {
      expect(start(enabled: false), isNull);
    });
  });

  group('recovery set', () {
    final now = DateTime.utc(2026, 10, 10);
    final set = ColituRecoverySet.parse({
      'generated_at': '2026-10-10T00:00:00Z',
      'recovery_until': '2026-10-24T00:00:00Z',
      'configs': [
        {
          'revision': 1,
          'server': {'id': 'n1'},
          'profile': {
            'format': 'xray-mobile-v1',
            'payload': {
              'schema_version': 1,
              'protocol': 'trojan',
              'endpoint': {'host': 'n1.example.test', 'port': 443},
              'credentials': {'password': 'secret'},
              'transport': {'type': 'tcp'},
              'security': {'type': 'tls', 'server_name': 'x'},
            },
          },
        },
      ],
    });
    const network = APIException(
      APIErrorCode.networkUnavailable,
      'down',
    );

    ColituRecoveryDecision decide({required bool enabled}) =>
        ColituRecovery.decide(
          automatic: true,
          multihop: false,
          apiError: network,
          cacheUsable: false,
          set: set,
          now: now,
          enabled: enabled,
        );

    test('on: used after a network-level failure', () {
      expect(set, isNotNull);
      expect(decide(enabled: true), ColituRecoveryDecision.use);
    });

    test('off: never used', () {
      expect(decide(enabled: false), ColituRecoveryDecision.none);
    });

    test('off: no background fetch is due', () {
      bool due({required bool enabled}) => ColituRecovery.refreshDue(
        generatedAt: null,
        lastAttempt: null,
        now: now,
        enabled: enabled,
      );
      expect(due(enabled: true), isTrue);
      expect(due(enabled: false), isFalse);
    });
  });

  group('recovery fetch query', () {
    test('sends client_country in upper case when known', () {
      expect(recoveryQuery('se')['client_country'], 'SE');
      expect(recoveryQuery(' tr ')['client_country'], 'TR');
      expect(recoveryQuery('RU')['client_country'], 'RU');
    });

    test('omits it when unknown', () {
      expect(recoveryQuery(null).containsKey('client_country'), isFalse);
      expect(recoveryQuery('').containsKey('client_country'), isFalse);
      expect(recoveryQuery('  ').containsKey('client_country'), isFalse);
      expect(recoveryQuery(null).containsKey('_ts'), isTrue);
    });
  });
}
