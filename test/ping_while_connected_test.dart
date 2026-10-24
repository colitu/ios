import 'dart:async';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/server_latency.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/shell/locations_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VPNServer _server(String id) => VPNServer(
  id: id,
  name: id,
  country: 'DE',
  status: 'online',
  available: true,
  locked: false,
  isPremium: false,
  isFree: true,
  isRecommended: false,
  host: '$id.example.test',
  port: 443,
);

const _hint = 'Ping is the last reading from before you connected';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ServerLatency.shownPing', () {
    final now = DateTime(2026, 10, 12, 12);
    ColituPing ping(int? ms, {Duration age = Duration.zero, String net = 'wifi|a'}) =>
        ColituPing(ms: ms, at: now.subtract(age), network: net);

    test('a reading on this network within 30 minutes is shown', () {
      expect(
        ServerLatency.shownPing(
          ping(42, age: const Duration(minutes: 29)),
          network: 'wifi|a',
          now: now,
        ),
        42,
      );
    });

    test('another network, an old reading or a failed one is not', () {
      expect(
        ServerLatency.shownPing(ping(42), network: 'cellular|a', now: now),
        isNull,
      );
      expect(
        ServerLatency.shownPing(
          ping(42, age: const Duration(minutes: 30)),
          network: 'wifi|a',
          now: now,
        ),
        isNull,
      );
      expect(
        ServerLatency.shownPing(
          ping(42, age: const Duration(minutes: -1)),
          network: 'wifi|a',
          now: now,
        ),
        isNull,
      );
      expect(
        ServerLatency.shownPing(ping(null), network: 'wifi|a', now: now),
        isNull,
      );
      expect(ServerLatency.shownPing(null, network: 'wifi|a', now: now), isNull);
    });
  });

  group('controller', () {
    test('skips measuring while connected and keeps the direct reading', () async {
      final server = _server('de');
      // No tunnel extension to ask (as on Android/desktop builds).
      final c = ColituConnectionController()
        ..servers = [server]
        ..tunnelLatencyProbe = null;
      addTearDown(c.dispose);
      var calls = 0;
      var answer = 40;
      c.latencyProbe = (host, port) async {
        calls++;
        return answer;
      };

      await c.measurePings();
      expect(calls, 1);
      expect(c.pingOf(server), 40);
      expect(c.pingsPaused, isFalse);

      // Through the tunnel the number would be wrong: nothing is dialled.
      answer = 300;
      for (final status in [
        ColituVpnStatus.connecting,
        ColituVpnStatus.connected,
        ColituVpnStatus.disconnecting,
      ]) {
        c.status = status;
        await c.measurePings();
        expect(calls, 1, reason: '$status');
        expect(c.pingsPaused, isTrue);
        expect(c.pingOf(server), 40, reason: 'cached reading while $status');
      }

      // VPN off again: measuring goes on.
      c.status = ColituVpnStatus.disconnected;
      await c.measurePings();
      expect(calls, 2);
      expect(c.pingOf(server), 300);
    });
  });

  group('measureAllOutside', () {
    Future<InternetAddress?> fakeResolve(String host) async {
      if (host.startsWith('dead')) return null;
      final n =
          int.tryParse(host.split('.').first.replaceAll(RegExp(r'\D'), '')) ??
          0;
      return InternetAddress('203.0.113.${n % 250 + 1}');
    }

    test(
      'one connect per address, 40 per request, results by server',
      () async {
        final servers = [
          for (var i = 0; i < 45; i++) _server('s$i'),
          // Same probe host as s1: measured once, reported for both.
          VPNServer(
            id: 'twin',
            name: 'twin',
            country: 'DE',
            status: 'online',
            available: true,
            locked: false,
            isPremium: false,
            isFree: true,
            isRecommended: false,
            host: 's1.example.test',
            port: 443,
          ),
          _server('dead1'),
        ];
        final batches = <int>[];
        final measured = await ServerLatency.measureAllOutside(
          servers,
          resolve: fakeResolve,
          send: (targets) async {
            batches.add(targets.length);
            return [
              for (final t in targets) int.parse(t.address.split('.').last),
            ];
          },
        );
        expect(batches, [40, 5]);
        expect(measured['s1'], 2);
        expect(measured['twin'], 2);
        expect(measured['s44'], 45);
        // A probe name that does not resolve counts as failed, as off-VPN.
        expect(measured.containsKey('dead1'), isTrue);
        expect(measured['dead1'], isNull);
      },
    );

    test('no answer from the extension: nothing measured', () async {
      final measured = await ServerLatency.measureAllOutside(
        [_server('s1'), _server('s2')],
        resolve: fakeResolve,
        send: (targets) async => null,
      );
      expect(measured, isEmpty);
    });

    test(
      'a failed connect is null, a later batch without answer is left out',
      () async {
        final servers = [for (var i = 0; i < 41; i++) _server('s$i')];
        var call = 0;
        final measured = await ServerLatency.measureAllOutside(
          servers,
          resolve: fakeResolve,
          send: (targets) async {
            call++;
            if (call == 2) throw StateError('extension gone');
            return [
              for (final t in targets) t.address.endsWith('.1') ? null : 30,
            ];
          },
        );
        expect(measured['s0'], isNull);
        expect(measured.containsKey('s0'), isTrue);
        expect(measured['s5'], 30);
        expect(measured.containsKey('s40'), isFalse);
      },
    );
  });

  group('controller while connected', () {
    test(
      'the extension measures outside the tunnel, at most every 30 s',
      () async {
        final server = _server('de');
        final c = ColituConnectionController()
          ..servers = [server]
          ..latencyResolver = (host) async => InternetAddress('203.0.113.7');
        addTearDown(c.dispose);
        var direct = 0;
        c.latencyProbe = (host, port) async {
          direct++;
          return 40;
        };
        var sent = <TunnelLatencyTarget>[];
        var asked = 0;
        c.tunnelLatencyProbe = (targets) async {
          asked++;
          sent = targets;
          return [55];
        };

        await c.measurePings();
        expect(c.pingOf(server), 40);

        c.status = ColituVpnStatus.connecting;
        await c.measurePings();
        expect(asked, 0, reason: 'nothing is measured while connecting');
        expect(c.pingsPaused, isTrue);

        c.status = ColituVpnStatus.connected;
        await c.measurePings();
        expect(asked, 1);
        expect(direct, 1, reason: 'the app never dials through the tunnel');
        expect(sent.single.address, '203.0.113.7');
        expect(sent.single.port, 443);
        expect(c.pingOf(server), 55);
        expect(c.pingsPaused, isFalse);

        await c.measurePings();
        expect(asked, 1, reason: 'rate limited');
        expect(c.pingOf(server), 55);
      },
    );

    test(
      'no answer from the extension keeps the last reading and says so',
      () async {
        final server = _server('de');
        final c = ColituConnectionController()
          ..servers = [server]
          ..latencyResolver = (host) async => InternetAddress('203.0.113.7');
        addTearDown(c.dispose);
        c.latencyProbe = (host, port) async => 40;
        c.tunnelLatencyProbe = (targets) async => null;

        await c.measurePings();
        c.status = ColituVpnStatus.connected;
        await c.measurePings();
        expect(c.pingOf(server), 40);
        expect(c.pingsPaused, isTrue);
      },
    );
  });

  group('LocationsTab', () {
    testWidgets('shows the cached-ping hint while connected and measures '
        'again once disconnected', (tester) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = ColituConnectionController()
        ..loading = false
        ..servers = [_server('de')]
        ..tunnelLatencyProbe = null
        ..status = ColituVpnStatus.connected;
      var calls = 0;
      c.latencyProbe = (host, port) async {
        calls++;
        return 30;
      };
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ColituTheme.dark,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (context, _) => LocationsTab(controller: c),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(_hint), findsOneWidget);
      expect(calls, 0);

      await tester.runAsync(() async {
        // Created in the real zone so its completion is seen here.
        final measured = Completer<void>();
        c.latencyProbe = (host, port) async {
          calls++;
          if (!measured.isCompleted) measured.complete();
          return 30;
        };
        c.status = ColituVpnStatus.disconnected;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        c.notifyListeners();
        await measured.future.timeout(const Duration(seconds: 10));
      });
      await tester.pump(const Duration(milliseconds: 600));
      expect(calls, 1);
      expect(find.text(_hint), findsNothing);
    });
  });
}
