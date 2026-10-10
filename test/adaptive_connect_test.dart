import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:flutter_test/flutter_test.dart';

VPNServer _server(String id, String country, {bool available = true}) =>
    VPNServer.fromJson({
      'id': id,
      'name': id,
      'countryCode': country,
      'available': available,
    });

void main() {
  final now = DateTime(2026, 10, 9, 12);
  const wifi = 'wifi|TR-AS1';
  const lte = 'cellular|TR-AS2';

  ColituPing ping(int? ms, {Duration age = Duration.zero, String net = wifi}) =>
      ColituPing(ms: ms, at: now.subtract(age), network: net);

  group('network key and link', () {
    test('key joins link and client network', () {
      expect(colituNetworkKey('wifi', 'TR-AS9121'), 'wifi|TR-AS9121');
      expect(colituNetworkKey('cellular', ''), 'cellular|');
    });

    test('Wi-Fi wins over cellular; local-only addresses do not count', () {
      expect(
        colituLinkKind([
          ('pdp_ip0', [false]),
          ('en0', [false]),
        ]),
        'wifi',
      );
      expect(
        colituLinkKind([
          ('en0', [true]),
          ('pdp_ip0', [false]),
        ]),
        'cellular',
      );
      expect(colituLinkKind([('en3', [false])]), 'ethernet');
      expect(colituLinkKind([('utun4', [false]), ('lo0', [true])]), 'other');
    });
  });

  group('ranking', () {
    final de = _server('de', 'DE');
    final nl = _server('nl', 'NL');
    final tr = _server('tr', 'TR');
    final fi = _server('fi', 'FI');
    final panel = [de, nl, tr, fi];

    List<String> rank(
      List<VPNServer> servers, {
      Map<String, ColituPing> pings = const {},
      ColituAdaptiveMemory? memory,
      String network = wifi,
      String? country,
    }) => [
      for (final s in rankServers(
        servers,
        pings: pings,
        memory: memory ?? ColituAdaptiveMemory(),
        network: network,
        clientCountry: country,
        now: now,
      ))
        s.id,
    ];

    test('without pings or memory the panel order stays', () {
      expect(rank(panel), ['de', 'nl', 'tr', 'fi']);
    });

    test('multihop routes and unavailable servers are left out', () {
      final route = VPNServer.parseMultihop([
        {
          'id': 'r1',
          'name': 'FI → DE',
          'country': 'DE',
          'multihop': true,
          'entry': {'node_id': 'n-fi', 'country': 'FI'},
          'exit': {'node_id': 'n-de', 'country': 'DE'},
        },
      ]).single;
      expect(rank([route, _server('x', 'US', available: false), de]), ['de']);
    });

    test('fresh successful pings first, fastest first, then panel order', () {
      expect(
        rank(panel, pings: {'fi': ping(30), 'nl': ping(80)}),
        ['fi', 'nl', 'de', 'tr'],
      );
    });

    test('old pings and pings from another network do not count', () {
      expect(
        rank(
          panel,
          pings: {
            'fi': ping(30, age: const Duration(minutes: 11)),
            'nl': ping(20, net: lte),
          },
        ),
        ['de', 'nl', 'tr', 'fi'],
      );
    });

    test('a fresh failed ping goes after the others but before penalized', () {
      final memory = ColituAdaptiveMemory()..penalize(wifi, 'nl', now);
      expect(
        rank(panel, pings: {'de': ping(null)}, memory: memory),
        ['tr', 'fi', 'de', 'nl'],
      );
    });

    test('the user\'s own country goes after the foreign ones', () {
      expect(rank(panel, country: 'TR', pings: {'tr': ping(5)}), [
        'de',
        'nl',
        'fi',
        'tr',
      ]);
      // Unknown country: no rule.
      expect(rank(panel, country: '', pings: {'tr': ping(5)}).first, 'tr');
    });

    test('the last-good server on this network comes first', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(wifi, 'fi', 'hysteria2', now);
      expect(
        rank(panel, pings: {'de': ping(10)}, memory: memory).first,
        'fi',
      );
      // Another network: the memory does not apply.
      expect(rank(panel, memory: memory, network: lte).first, 'de');
    });

    test('a penalty beats the last-good mark and expires after 30 min', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(wifi, 'de', 'trojan', now)
        ..penalize(wifi, 'de', now);
      expect(rank(panel, memory: memory).last, 'de');
      expect(
        rankServers(
          panel,
          pings: const {},
          memory: memory,
          network: wifi,
          now: now.add(const Duration(minutes: 31)),
        ).first.id,
        'de',
      );
    });
  });

  group('memory', () {
    test('entries expire by kind', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(wifi, 'de', 'vless-reality', now)
        // A confirmed stall (6 h); a tentative one is in adaptive_connect2.
        ..markStalled(wifi, 'de', 'hysteria2', now, tentative: false)
        ..penalize(wifi, 'nl', now);
      DateTime after(Duration d) => now.add(d);

      expect(memory.lastGoodServer(wifi, now), 'de');
      expect(memory.lastGoodTransport(wifi, 'de', now), 'vless-reality');
      expect(memory.stalledTransports(wifi, 'de', now), {'hysteria2'});
      expect(memory.isPenalized(wifi, 'nl', now), isTrue);

      final halfHour = after(const Duration(minutes: 30));
      expect(memory.isPenalized(wifi, 'nl', halfHour), isFalse);
      expect(memory.stalledTransports(wifi, 'de', halfHour), {'hysteria2'});

      final sixHours = after(const Duration(hours: 6));
      expect(memory.stalledTransports(wifi, 'de', sixHours), isEmpty);
      expect(memory.lastGoodServer(wifi, sixHours), 'de');

      final day = after(const Duration(hours: 24));
      expect(memory.lastGoodServer(wifi, day), isNull);
      expect(memory.lastGoodTransport(wifi, 'de', day), isNull);
    });

    test('memory is kept per network', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(wifi, 'de', 'trojan', now)
        ..markStalled(wifi, 'de', 'hysteria2', now);
      expect(memory.lastGoodServer(lte, now), isNull);
      expect(memory.stalledTransports(lte, 'de', now), isEmpty);
    });

    test('a stall on a second server counts for the whole network', () {
      final memory = ColituAdaptiveMemory()
        ..markStalled(wifi, 'de', 'hysteria2', now);
      expect(memory.stalledTransports(wifi, 'nl', now), isEmpty);
      memory.markStalled(wifi, 'nl', 'hysteria2', now);
      expect(memory.stalledTransports(wifi, 'fi', now), {'hysteria2'});
    });

    test('success clears the penalty and the stall of that transport', () {
      final memory = ColituAdaptiveMemory()
        ..penalize(wifi, 'de', now)
        ..markStalled(wifi, 'de', 'trojan', now)
        ..recordSuccess(wifi, 'de', 'trojan', now);
      expect(memory.isPenalized(wifi, 'de', now), isFalse);
      expect(memory.stalledTransports(wifi, 'de', now), isEmpty);
    });

    test('encode and decode round-trip and prune expired entries', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(wifi, 'de', 'trojan', now)
        ..penalize(wifi, 'nl', now);
      final raw = memory.encode();

      final soon = ColituAdaptiveMemory.decode(raw, now);
      expect(soon.length, 3);
      expect(soon.lastGoodTransport(wifi, 'de', now), 'trojan');
      expect(soon.isPenalized(wifi, 'nl', now), isTrue);

      final later = ColituAdaptiveMemory.decode(
        raw,
        now.add(const Duration(hours: 1)),
      );
      expect(later.length, 2);
      expect(ColituAdaptiveMemory.decode('not json', now).length, 0);
      expect(ColituAdaptiveMemory.decode(null, now).length, 0);
    });

    test('the store is capped; the oldest entries go first', () {
      final memory = ColituAdaptiveMemory(cap: 5);
      for (var i = 0; i < 8; i++) {
        memory.penalize(wifi, 's$i', now.add(Duration(seconds: i)));
      }
      final at = now.add(const Duration(seconds: 10));
      expect(memory.length, 5);
      expect(memory.isPenalized(wifi, 's0', at), isFalse);
      expect(memory.isPenalized(wifi, 's7', at), isTrue);
    });
  });

  group('pings', () {
    test('fresh only on the same network for 10 minutes', () {
      expect(ping(40).isFresh(wifi, now), isTrue);
      expect(ping(40).isFresh(lte, now), isFalse);
      expect(
        ping(40, age: const Duration(minutes: 10)).isFresh(wifi, now),
        isFalse,
      );
    });

    test('stored pings round-trip; the old number-only format is not fresh', () {
      final raw = ColituPing.encodeAll({'de': ping(40), 'nl': ping(null)});
      final decoded = ColituPing.decodeAll(raw);
      expect(decoded['de']!.ms, 40);
      expect(decoded['nl']!.failed, isTrue);
      expect(decoded['nl']!.isFresh(wifi, now), isTrue);

      final legacy = ColituPing.decodeAll('{"de": 55}');
      expect(legacy['de']!.ms, 55);
      expect(legacy['de']!.isFresh(wifi, now), isFalse);
    });
  });
}
