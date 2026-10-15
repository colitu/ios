import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/server_latency.dart';
import 'package:flutter_test/flutter_test.dart';

VPNServer _server(String id, {String? host = 'node.example.test', int? port = 443}) =>
    VPNServer(
      id: id,
      name: id,
      country: 'XX',
      status: 'online',
      available: true,
      locked: false,
      isPremium: false,
      isFree: true,
      isRecommended: false,
      host: host,
      port: port,
    );

bool _public(String ip) => ServerLatency.isPublic(InternetAddress(ip));

void main() {
  group('isPublic', () {
    test('rejects loopback, private, CGNAT, link-local and reserved IPv4', () {
      for (final ip in [
        '0.0.0.0', '10.1.2.3', '127.0.0.1', '100.64.0.1', '100.127.255.254',
        '169.254.1.1', '172.16.0.1', '172.31.255.255', '192.168.1.1',
        '192.0.0.1', '192.0.2.1', '198.18.0.1', '198.51.100.1',
        '203.0.113.1', '224.0.0.1', '255.255.255.255',
      ]) {
        expect(_public(ip), isFalse, reason: ip);
      }
    });

    test('rejects local and reserved IPv6, judges embedded IPv4', () {
      for (final ip in [
        '::', '::1', 'fe80::1', 'fec0::1', 'fd00::1', 'fc00::1', 'ff02::1',
        '2001:db8::1', '::ffff:10.0.0.1', '::ffff:127.0.0.1',
        '64:ff9b::a00:1', '64:ff9b::7f00:1',
      ]) {
        expect(_public(ip), isFalse, reason: ip);
      }
      expect(_public('::ffff:8.8.8.8'), isTrue);
      expect(_public('64:ff9b::808:808'), isTrue);
      expect(_public('2a00:1450::1'), isTrue);
    });

    test('accepts public IPv4', () {
      for (final ip in ['1.1.1.1', '8.8.8.8', '100.63.0.1', '100.128.0.1', '172.32.0.1']) {
        expect(_public(ip), isTrue, reason: ip);
      }
    });
  });

  group('resolvePublic', () {
    test('refuses a name that resolves (even partly) to a private address', () async {
      final resolved = await ServerLatency.resolvePublic(
        'node.example.test',
        lookup: (_) async => [InternetAddress('8.8.8.8'), InternetAddress('10.0.0.1')],
      );
      expect(resolved, isNull);
      expect(
        await ServerLatency.resolvePublic(
          'node.example.test',
          lookup: (_) async => [InternetAddress('127.0.0.1')],
        ),
        isNull,
      );
    });

    test('returns the first address when all are public', () async {
      final resolved = await ServerLatency.resolvePublic(
        'node.example.test',
        lookup: (_) async => [InternetAddress('8.8.8.8'), InternetAddress('1.1.1.1')],
      );
      expect(resolved?.address, '8.8.8.8');
    });

    test('a failed lookup is null', () async {
      expect(
        await ServerLatency.resolvePublic(
          'node.example.test',
          lookup: (_) async => throw const SocketException('no'),
        ),
        isNull,
      );
    });
  });

  group('measureAll', () {
    test('only allowed ports are probed', () async {
      final probed = <int>[];
      final result = await ServerLatency.measureAll(
        [
          _server('a', port: 443),
          _server('b', port: 22),
          _server('c', port: 8443),
          _server('d', port: 80),
          _server('e', port: null),
          _server('f', host: ''),
        ],
        probe: (host, port) async {
          probed.add(port);
          return 10;
        },
      );
      expect(probed..sort(), [443, 8443]);
      expect(result.keys.toSet(), {'a', 'c'});
      expect(ServerLatency.allowedPorts, {
        443, 2053, 2083, 2087, 2096, 3443, 4433, 7443, 8388, 8443, 9443,
      });
    });

    test('measure refuses a port outside the list without dialling', () async {
      expect(await ServerLatency.measure('127.0.0.1', 22), isNull);
    });

    test('caps the run at 200 probes and 8 at once', () async {
      final servers = [for (var i = 0; i < 500; i++) _server('s$i')];
      var inFlight = 0;
      var peak = 0;
      var calls = 0;
      final result = await ServerLatency.measureAll(
        servers,
        probe: (host, port) async {
          calls++;
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          inFlight--;
          return 5;
        },
      );
      expect(calls, ServerLatency.maxProbes);
      expect(result.length, 200);
      expect(peak, lessThanOrEqualTo(ServerLatency.concurrency));
      expect(peak, greaterThan(1));
    });

    test('a probe that throws counts as unreachable', () async {
      final result = await ServerLatency.measureAll(
        [_server('a'), _server('b')],
        probe: (host, port) async => throw StateError('x'),
      );
      expect(result, {'a': null, 'b': null});
    });
  });
}
