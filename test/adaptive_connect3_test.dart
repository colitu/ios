import 'dart:async';

import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/recovery_set.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adaptive Connect 3.0: preferred network hints and the recovery set
/// (docs/adaptive-connect-3-apps.md in the panel repository).
void main() {
  const isp = 'TR-AS1';

  group('preferred hints', () {
    Map<String, Object?> body(Object? preferred, [Object? blocked = const []]) =>
        {
          'network_token': 'abc',
          'network_hints': {
            'blocked': blocked,
            'preferred': preferred,
            'scope': 'network',
          },
        };

    test('parsed like blocked: lowercase, trimmed, no duplicates', () {
      final read = ColituNetworkHints.fromServers(
        body([' Hysteria2 ', 'trojan', 'HYSTERIA2', '', 7, 'vless-reality']),
        isp,
      )!;
      expect(read.preferred, ['hysteria2', 'trojan', 'vless-reality']);
    });

    test('a protocol that is also blocked is dropped', () {
      final read = ColituNetworkHints.fromServers(
        body(['hysteria2', 'trojan'], ['Hysteria2']),
        isp,
      )!;
      expect(read.blocked, {'hysteria2'});
      expect(read.preferred, ['trojan']);
    });

    test('hints may carry preferred with an empty blocked list', () {
      final read = ColituNetworkHints.fromServers(body(['trojan']), isp)!;
      expect(read.blocked, isEmpty);
      expect(read.preferred, ['trojan']);
      // no preferred at all: empty
      expect(
        ColituNetworkHints.fromServers({
          'network_hints': {'blocked': <String>[]},
        }, isp)!.preferred,
        isEmpty,
      );
    });

    test('stored with the record; an old record reads as empty', () {
      final stored = ColituNetworkHints.fromServers(
        body(['trojan', 'hysteria2']),
        isp,
      )!;
      final back = ColituNetworkHints.decode(
        '{"network":"TR-AS1","token":"t","blocked":[],"preferred":["trojan","hysteria2"],"scope":"network"}',
      );
      expect(back.preferred, stored.preferred);
      final old = ColituNetworkHints.decode(
        '{"network":"TR-AS1","token":"t","blocked":["trojan"],"scope":"country"}',
      );
      expect(old.preferred, isEmpty);
      expect(old.blocked, {'trojan'});
    });

    test('only counts on the network it came with', () {
      final hints = ColituNetworkHints(
        clientNetwork: isp,
        preferred: const ['trojan'],
      );
      expect(hints.preferredFor(isp), ['trojan']);
      expect(hints.preferredFor('TR-AS2'), isEmpty);
      expect(ColituNetworkHints.none.preferredFor(''), isEmpty);
    });
  });

  group('hinted start', () {
    const offered = ['hysteria2', 'vless-reality', 'trojan', 'shadowsocks'];

    List<String> rank(List<String> rest) => [...rest]..sort(
      (a, b) => ColituVPNConfigAdapter.transportRankFor(
        a,
      ).compareTo(ColituVPNConfigAdapter.transportRankFor(b)),
    );

    ({List<String> order, int hinted})? start({
      List<String> preferred = const ['trojan', 'vless-reality'],
      Set<String> stalled = const {},
      String? lastGood,
      List<String> configs = offered,
    }) => colituHintedStart<String>(
      configs,
      protocolOf: (c) => c,
      preferred: preferred,
      stalled: stalled,
      lastGood: lastGood,
      rank: rank,
    );

    test('no memory: the preferred go first in the hint order, rest ranked', () {
      final result = start()!;
      expect(result.order, [
        'trojan',
        'vless-reality',
        'hysteria2',
        'shadowsocks',
      ]);
      expect(result.hinted, 2);
    });

    test('own memory of the network always wins', () {
      expect(start(lastGood: 'hysteria2'), isNull);
    });

    test('stalled and not offered protocols are skipped', () {
      final result = start(
        preferred: const ['trojan', 'vless-xhttp', 'vless-reality'],
        stalled: const {'trojan'},
      )!;
      expect(result.order.first, 'vless-reality');
      expect(result.hinted, 1);
    });

    test('nothing usable or no hint: the usual order decides', () {
      expect(start(preferred: const []), isNull);
      expect(start(preferred: const ['vless-xhttp']), isNull);
      expect(start(stalled: const {'trojan', 'vless-reality'}), isNull);
    });
  });

  group('recovery set parse', () {
    Map<String, Object?> envelope(String id, [String protocol = 'trojan']) => {
      'revision': 1,
      'expires_at': '2099-01-01T00:00:00Z',
      'server': {'id': id, 'country': 'DE'},
      'profile': {
        'format': 'xray-mobile-v1',
        'payload': {
          'schema_version': 1,
          'protocol': protocol,
          'endpoint': {'host': '$id.example.test', 'port': 443},
          'credentials': {'password': 'secret'},
          'transport': {'type': 'tcp'},
          'security': {'type': 'tls', 'server_name': '$id.example.test'},
        },
      },
    };

    Map<String, Object?> set({
      List<Object?>? configs,
      Object? until = '2026-10-24T12:00:00Z',
      Object? generated = '2026-10-10T12:00:00Z',
    }) => {
      'generated_at': generated,
      'recovery_until': until,
      'configs': configs ?? [envelope('n1'), envelope('n2')],
    };

    test('a valid set', () {
      final parsed = ColituRecoverySet.parse(set())!;
      expect(parsed.configs.map((c) => c.serverId), ['n1', 'n2']);
      expect(parsed.recoveryUntil, DateTime.utc(2026, 10, 24, 12));
      expect(parsed.generatedAt, DateTime.utc(2026, 10, 10, 12));
      // the stored text parses back to the same set
      final again = ColituRecoverySet.parse(parsed.raw)!;
      expect(again.configs.length, 2);
    });

    test('empty configs are rejected', () {
      expect(ColituRecoverySet.parse(set(configs: [])), isNull);
      expect(ColituRecoverySet.parse(set(configs: [{'x': 1}])), isNull);
    });

    test('a bad recovery_until is rejected', () {
      expect(ColituRecoverySet.parse(set(until: 'soon')), isNull);
      expect(ColituRecoverySet.parse(set(until: null)), isNull);
      expect(ColituRecoverySet.parse(set(generated: 5)), isNull);
      expect(ColituRecoverySet.parse('not json'), isNull);
      expect(ColituRecoverySet.parse([1]), isNull);
    });

    test('at most 4 envelopes; a malformed one is skipped', () {
      final parsed = ColituRecoverySet.parse(
        set(
          configs: [
            envelope('a'),
            {
              ...envelope('b'),
              'profile': {'format': 'other'},
            },
            envelope('c'),
            envelope('d'),
            envelope('e'),
            envelope('f'),
          ],
        ),
      )!;
      expect(parsed.configs.map((c) => c.serverId), ['a', 'c', 'd', 'e']);
    });
  });

  group('recovery decisions', () {
    final now = DateTime.utc(2026, 10, 12);
    ColituRecoverySet makeSet(String until) => ColituRecoverySet.parse({
      'generated_at': '2026-10-10T12:00:00Z',
      'recovery_until': until,
      'configs': [
        for (final id in ['n1', 'n2', 'n3'])
          {
            'revision': 1,
            'server': {'id': id},
            'profile': {
              'format': 'xray-mobile-v1',
              'payload': {
                'schema_version': 1,
                'protocol': 'trojan',
                'endpoint': {'host': '$id.example.test', 'port': 443},
                'credentials': {'password': 'secret'},
                'transport': {'type': 'tcp'},
                'security': {'type': 'tls', 'server_name': 'x'},
              },
            },
          },
      ],
    })!;

    final network = const APIException(
      APIErrorCode.networkUnavailable,
      'offline',
    );

    ColituRecoveryDecision decide({
      bool automatic = true,
      bool multihop = false,
      Object? error,
      bool cacheUsable = false,
      ColituRecoverySet? set,
      String until = '2026-10-24T12:00:00Z',
    }) => ColituRecovery.decide(
      automatic: automatic,
      multihop: multihop,
      apiError: error ?? network,
      cacheUsable: cacheUsable,
      set: set ?? makeSet(until),
      now: now,
    );

    test('used only on a network-level API failure with no usable cache', () {
      expect(decide(), ColituRecoveryDecision.use);
      expect(
        decide(error: TimeoutException('config')),
        ColituRecoveryDecision.use,
      );
      expect(decide(cacheUsable: true), ColituRecoveryDecision.none);
      for (final error in <Object>[
        const APIException(
          APIErrorCode.backendUnavailable,
          '5xx',
          statusCode: 503,
        ),
        const APIException(
          APIErrorCode.subscriptionInactive,
          'plan',
          statusCode: 403,
        ),
        const APIException(APIErrorCode.unauthorized, 'no', statusCode: 401),
        const APIException(APIErrorCode.unknown, 'tls'),
        StateError('x'),
      ]) {
        expect(decide(error: error), ColituRecoveryDecision.none, reason: '$error');
      }
    });

    test('only in automatic mode, not for a picked server or multihop', () {
      expect(decide(automatic: false), ColituRecoveryDecision.none);
      expect(decide(multihop: true), ColituRecoveryDecision.none);
      expect(
        ColituRecovery.decide(
          automatic: true,
          multihop: false,
          apiError: network,
          cacheUsable: false,
          set: null,
          now: now,
        ),
        ColituRecoveryDecision.none,
      );
    });

    test('past recovery_until: not used, to be deleted', () {
      expect(
        decide(until: '2026-10-12T00:00:00Z'),
        ColituRecoveryDecision.expired,
      );
      expect(
        decide(until: '2026-10-11T00:00:00Z'),
        ColituRecoveryDecision.expired,
      );
      expect(
        decide(until: '2026-10-12T00:00:01Z'),
        ColituRecoveryDecision.use,
      );
    });

    test('servers are tried in order, failed ones skipped', () {
      final set = makeSet('2026-10-24T12:00:00Z');
      expect(ColituRecovery.next(set, const [])!.serverId, 'n1');
      expect(ColituRecovery.next(set, const ['n1'])!.serverId, 'n2');
      expect(
        ColituRecovery.serversToTry(set, const ['n2']).map((c) => c.serverId),
        ['n1', 'n3'],
      );
      expect(ColituRecovery.next(set, const ['n1', 'n2', 'n3']), isNull);
    });

    test('401/403 on fetch delete the set; network errors and 5xx keep it', () {
      for (final status in [401, 403]) {
        expect(
          ColituRecovery.dropsSet(
            APIException(APIErrorCode.unauthorized, 'x', statusCode: status),
          ),
          isTrue,
        );
      }
      expect(ColituRecovery.dropsSet(network), isFalse);
      expect(
        ColituRecovery.dropsSet(
          const APIException(
            APIErrorCode.backendUnavailable,
            'x',
            statusCode: 503,
          ),
        ),
        isFalse,
      );
      expect(ColituRecovery.dropsSet(TimeoutException('x')), isFalse);
    });
  });

  group('recovery refresh', () {
    final now = DateTime.utc(2026, 10, 12, 12);

    test('due with no stored set, if not tried within 6 h', () {
      expect(
        ColituRecovery.refreshDue(
          generatedAt: null,
          lastAttempt: null,
          now: now,
        ),
        isTrue,
      );
      expect(
        ColituRecovery.refreshDue(
          generatedAt: null,
          lastAttempt: now.subtract(const Duration(hours: 5, minutes: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        ColituRecovery.refreshDue(
          generatedAt: null,
          lastAttempt: now.subtract(const Duration(hours: 6)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a stored set is refreshed after 24 h', () {
      expect(
        ColituRecovery.refreshDue(
          generatedAt: now.subtract(const Duration(hours: 23)),
          lastAttempt: null,
          now: now,
        ),
        isFalse,
      );
      expect(
        ColituRecovery.refreshDue(
          generatedAt: now.subtract(const Duration(hours: 25)),
          lastAttempt: now.subtract(const Duration(hours: 7)),
          now: now,
        ),
        isTrue,
      );
      // a failed attempt an hour ago holds the next one back
      expect(
        ColituRecovery.refreshDue(
          generatedAt: now.subtract(const Duration(hours: 25)),
          lastAttempt: now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
