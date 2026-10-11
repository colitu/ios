import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:flutter_test/flutter_test.dart';

VPNServer _server(String id, String country) => VPNServer.fromJson({
  'id': id,
  'name': id,
  'countryCode': country,
  'available': true,
});

/// Regression tests for the two ranking bugs fixed on Android and Windows:
/// a server picked by hand must not become the "last good" one, and a server
/// in the client's own country is only pushed back where that country
/// censors.
void main() {
  final now = DateTime(2026, 10, 11, 12);
  const net = 'wifi|DE-AS3320';

  ColituPing ping(int? ms) => ColituPing(ms: ms, at: now, network: net);

  List<String> rank(
    List<VPNServer> servers, {
    Map<String, ColituPing> pings = const {},
    ColituAdaptiveMemory? memory,
    String? country,
  }) => [
    for (final s in rankServers(
      servers,
      pings: pings,
      memory: memory ?? ColituAdaptiveMemory(),
      network: net,
      clientCountry: country,
      now: now,
    ))
      s.id,
  ];

  final us = _server('us', 'US');
  final nl = _server('nl', 'NL');
  final de = _server('de', 'DE');
  final tr = _server('tr', 'TR');

  group('last good server comes from automatic connections only', () {
    test('Europe client, US picked by hand: the nearby fast server is first', () {
      final memory = ColituAdaptiveMemory()
        // The manual pick of a faraway server (what the old code remembered).
        ..recordSuccess(net, 'us', 'trojan', now, goodServer: false);
      expect(memory.lastGoodServer(net, now), isNull);
      // The transport is still remembered for that server.
      expect(memory.lastGoodTransport(net, 'us', now), 'trojan');
      expect(
        rank(
          [us, nl],
          pings: {'us': ping(150), 'nl': ping(20)},
          memory: memory,
          country: 'DE',
        ),
        ['nl', 'us'],
      );
    });

    test('a manual pick leaves an earlier automatic last-good server alone', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(net, 'nl', 'hysteria2', now)
        ..recordSuccess(net, 'us', 'trojan', now, goodServer: false);
      expect(memory.lastGoodServer(net, now), 'nl');
    });

    test('an automatic connection is remembered as before', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(net, 'nl', 'hysteria2', now);
      expect(memory.lastGoodServer(net, now), 'nl');
      expect(rank([us, nl, de], memory: memory).first, 'nl');
    });
  });

  group('the remembered server steps aside for a clearly faster one', () {
    final memory = ColituAdaptiveMemory()
      ..recordSuccess(net, 'us', 'hysteria2', now);

    test('at least 40 % and 60 ms faster: the fast one is first', () {
      expect(
        rank([us, nl], pings: {'us': ping(150), 'nl': ping(20)}, memory: memory),
        ['nl', 'us'],
      );
      // Exactly 40 % and exactly 60 ms are enough.
      expect(
        rank([us, nl], pings: {'us': ping(150), 'nl': ping(90)}, memory: memory),
        ['nl', 'us'],
      );
    });

    test('faster by less than 60 ms: the remembered server stays first', () {
      expect(
        rank([us, nl], pings: {'us': ping(100), 'nl': ping(45)}, memory: memory),
        ['us', 'nl'],
      );
    });

    test('faster by less than 40 %: the remembered server stays first', () {
      expect(
        rank([us, nl], pings: {'us': ping(400), 'nl': ping(300)}, memory: memory),
        ['us', 'nl'],
      );
    });

    test('without a fresh ping of the remembered server nothing changes', () {
      expect(rank([us, nl], pings: {'nl': ping(5)}, memory: memory), ['us', 'nl']);
    });

    test('a candidate without a fresh ping does not beat it', () {
      expect(rank([us, nl], pings: {'us': ping(300)}, memory: memory), ['us', 'nl']);
    });

    test('a failed server never beats it (different standing)', () {
      expect(
        rank([us, nl], pings: {'us': ping(300), 'nl': ping(null)}, memory: memory),
        ['us', 'nl'],
      );
    });
  });

  group('own-country servers are pushed back only where the country censors', () {
    test('NL client: NL at 5 ms beats US at 150 ms', () {
      expect(
        rank([us, nl], pings: {'us': ping(150), 'nl': ping(5)}, country: 'NL'),
        ['nl', 'us'],
      );
    });

    test('TR client: the TR server goes after DE even at 5 ms', () {
      expect(
        rank([tr, de], pings: {'tr': ping(5), 'de': ping(60)}, country: 'TR'),
        ['de', 'tr'],
      );
    });

    test('the censoring set is the documented one', () {
      expect(kHomePushbackCountries, {
        'RU', 'BY', 'KZ', 'UZ', 'TM', 'TJ', 'KG', 'AZ', 'IR', //
        'CN', 'TR', 'VN', 'PK', 'EG', 'SA', 'AE', 'ET', 'MM',
      });
      for (final code in kHomePushbackCountries.difference({'RU'})) {
        final home = _server('home', code);
        expect(
          rank([home, de], pings: {'home': ping(5), 'de': ping(60)}, country: code),
          ['de', 'home'],
          reason: code,
        );
      }
    });

    test('elsewhere the home server competes on latency', () {
      for (final code in ['DE', 'NL', 'US', 'GB', 'JP', 'FI', 'GE', 'UA']) {
        final home = _server('home', code);
        expect(
          rank([de, home], pings: {'home': ping(5), 'de': ping(60)}, country: code),
          ['home', 'de'],
          reason: code,
        );
      }
      expect(rank([nl, us], pings: {'nl': ping(5), 'us': ping(150)}, country: ''), ['nl', 'us']);
    });

    test('Russia stays out of automatic mode wherever the client is', () {
      final ru = _server('ru', 'RU');
      expect(kAutoExcludedCountries, {'RU'});
      for (final country in ['RU', 'TR', 'DE', null]) {
        expect(
          rank([ru, nl], pings: {'ru': ping(1), 'nl': ping(200)}, country: country),
          ['nl'],
        );
      }
    });

    test('a censoring-country client with a remembered home server keeps it last', () {
      final memory = ColituAdaptiveMemory()..recordSuccess(net, 'tr', 'trojan', now);
      expect(
        rank([tr, de], pings: {'tr': ping(5), 'de': ping(60)}, memory: memory, country: 'TR'),
        ['de', 'tr'],
      );
    });
  });
}
