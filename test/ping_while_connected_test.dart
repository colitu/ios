import 'dart:async';

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
      final c = ColituConnectionController()..servers = [server];
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

  group('LocationsTab', () {
    testWidgets('shows the cached-ping hint while connected and measures '
        'again once disconnected', (tester) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = ColituConnectionController()
        ..loading = false
        ..servers = [_server('de')]
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
