import 'dart:convert';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/warm_spare.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 9, 12);
  const isp = 'TR-AS1';
  const net = 'cellular|TR-AS1';

  ColituNetworkHints hints({Set<String> blocked = const {'hysteria2'}}) =>
      ColituNetworkHints(clientNetwork: isp, token: 'tok', blocked: blocked);

  group('blocked servers', () {
    VPNServer server(String id) => VPNServer.fromJson({
      'id': id,
      'name': id,
      'countryCode': 'DE',
      'available': true,
    });

    test('read from the server list, kept with the network', () {
      final parsed = ColituNetworkHints.fromServers({
        'network_hints': {
          'blocked': [],
          'blocked_servers': ['node-b', 'node-a'],
          'scope': 'country',
        },
      }, isp)!;
      expect(parsed.blockedServersFor(isp), {'node-a', 'node-b'});
      expect(parsed.blockedServersFor('TR-AS2'), isEmpty);
      final stored = ColituNetworkHints.decode(jsonEncode(parsed.toJson()));
      expect(stored.blockedServersFor(isp), {'node-a', 'node-b'});
      // A record stored before server hints reads as none.
      expect(
        ColituNetworkHints.decode('{"network":"$isp","blocked":[]}')
            .blockedServersFor(isp),
        isEmpty,
      );
    });

    test('hinted servers go last, before own penalties, except the last good one', () {
      final servers = [server('blocked'), server('own'), server('a'), server('good')];
      final memory = ColituAdaptiveMemory()
        ..penalize(net, 'own', now.subtract(const Duration(minutes: 5)))
        ..recordSuccess(net, 'good', 'vless-reality', now.subtract(const Duration(minutes: 10)));
      final pings = {
        for (final (id, ms) in [('blocked', 20), ('own', 30), ('a', 50), ('good', 60)])
          id: ColituPing(ms: ms, at: now.subtract(const Duration(minutes: 1)), network: net),
      };
      List<String> rank(Set<String> hinted) => [
        for (final s in rankServers(
          servers,
          pings: pings,
          memory: memory,
          network: net,
          clientCountry: 'RU',
          now: now,
          hintedServers: hinted,
        ))
          s.id,
      ];
      expect(rank({'blocked', 'good'}), ['good', 'a', 'blocked', 'own']);
      expect(rank(const {}), ['good', 'blocked', 'a', 'own']);
    });
  });

  group('server list', () {
    test('token and hints are read with a known network only', () {
      final body = {
        'network_token': 'abc',
        'network_hints': {
          'blocked': ['Hysteria2', ''],
          'scope': 'network',
          'updated_at': '2026-10-09T11:00:00Z',
        },
      };
      final read = ColituNetworkHints.fromServers(body, isp)!;
      expect(read.token, 'abc');
      expect(read.blocked, {'hysteria2'});
      expect(read.scope, 'network');
      // VPN on: no client_network, the stored hints stay.
      expect(ColituNetworkHints.fromServers(body, ''), isNull);
      // Known network without hints: nothing blocked.
      expect(
        ColituNetworkHints.fromServers({'network_token': 'x'}, isp)!.blocked,
        isEmpty,
      );
    });

    test('stored hints round-trip', () {
      final back = ColituNetworkHints.decode(
        '{"network":"TR-AS1","token":"t","blocked":["trojan"],"scope":"country"}',
      );
      expect(back.clientNetwork, isp);
      expect(back.blocked, {'trojan'});
      expect(ColituNetworkHints.decode('nope').token, isEmpty);
    });
  });

  group('observations', () {
    test('token only for the network it was issued on', () {
      expect(hints().tokenFor(isp), 'tok');
      expect(hints().tokenFor('TR-AS2'), isNull);
      expect(ColituNetworkHints.none.tokenFor(''), isNull);
    });

    test('body carries network_token when known', () {
      final obs = [
        {'protocol': 'hysteria2', 'reachable': false},
      ];
      expect(
        ColituVPNConfigAdapter.protocolObservationBody('n1', obs, 'tok'),
        {'node_id': 'n1', 'observations': obs, 'network_token': 'tok'},
      );
      expect(
        ColituVPNConfigAdapter.protocolObservationBody('n1', obs, null),
        {'node_id': 'n1', 'observations': obs},
      );
    });
  });

  group('ordering', () {
    test('hinted-blocked protocols go last on their network', () {
      final demoted = hints().demoted(
        currentClientNetwork: isp,
        network: net,
        memory: ColituAdaptiveMemory(),
        now: now,
      );
      expect(demoted, {'hysteria2'});
      final order = ['hysteria2', 'vless-reality', 'trojan']
        ..sort(
          (a, b) => ColituVPNConfigAdapter.transportRankFor(
            a,
            excluded: demoted,
          ).compareTo(
            ColituVPNConfigAdapter.transportRankFor(b, excluded: demoted),
          ),
        );
      expect(order, ['vless-reality', 'trojan', 'hysteria2']);
    });

    test('local experience in the last 24 h beats the hint', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(net, 'de', 'hysteria2', now);
      expect(
        hints().demoted(
          currentClientNetwork: isp,
          network: net,
          memory: memory,
          now: now,
        ),
        isEmpty,
      );
      expect(
        hints().demoted(
          currentClientNetwork: isp,
          network: net,
          memory: memory,
          now: now.add(const Duration(hours: 25)),
        ),
        {'hysteria2'},
      );
    });

    test('hints of another ISP network do not apply', () {
      expect(
        hints().demoted(
          currentClientNetwork: 'TR-AS2',
          network: 'wifi|TR-AS2',
          memory: ColituAdaptiveMemory(),
          now: now,
        ),
        isEmpty,
      );
    });
  });

  group('warm spare', () {
    test('never a hinted-blocked protocol unless nothing else is offered', () {
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-reality',
          offered: const ['vless-reality', 'hysteria2', 'trojan'],
          hinted: const {'hysteria2'},
          sameServer: true,
        ),
        'trojan',
      );
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-reality',
          offered: const ['vless-reality', 'hysteria2'],
          hinted: const {'hysteria2'},
          sameServer: true,
        ),
        'hysteria2',
      );
    });
  });
}
