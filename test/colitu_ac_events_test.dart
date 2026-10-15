import 'dart:async';

import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/services/colitu_ac_events.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';
import 'package:colitu_vpn/colitu/services/colitu_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryKv implements ColituKv {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }
}

const _n1 = '3f2b8c1e-0000-4000-8000-000000000001';
const _n2 = '3f2b8c1e-0000-4000-8000-000000000002';

APIException _api(APIErrorCode code, {String? backend}) =>
    APIException(code, 'x', backendCode: backend);

void main() {
  group('reason mapping', () {
    test('errors of the connect flow', () {
      expect(ColituAcEvents.reasonOfError(TimeoutException('x')), 'timeout');
      expect(ColituAcEvents.reasonOfError(const ColituVerifyException()), 'blocked');
      expect(ColituAcEvents.reasonOfError(const ColituVerifyException('')), 'blocked');
      expect(ColituAcEvents.reasonOfError(const ColituVerifyException('core_not_running')), 'core_crash');
      expect(ColituAcEvents.reasonOfError(const ColituVerifyException('no_socket_fd')), 'core_crash');
      expect(ColituAcEvents.reasonOfError(const ColituPlanRequiredException()), 'auth');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.networkUnavailable)), 'no_network');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.unauthorized)), 'auth');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.deviceOverLimit)), 'auth');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.premiumRequired)), 'auth');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.freeDailyLimitReached)), 'quota');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.unknown, backend: 'QUOTA_EXCEEDED')), 'quota');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.serverUnavailable)), 'other');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.configMissing)), 'other');
      expect(ColituAcEvents.reasonOfError(_api(APIErrorCode.vpnPermissionDenied)), 'other');
      expect(ColituAcEvents.reasonOfError(null), 'other');
    });

    test('codes as text; a reason stays a reason', () {
      for (final reason in ColituAcEvents.reasons) {
        expect(ColituAcEvents.reasonOf(reason), reason);
        expect(ColituAcEvents.reasonOf(reason.toUpperCase()), reason);
      }
      expect(ColituAcEvents.reasonOf('TUNNEL_TIMEOUT'), 'timeout');
      expect(ColituAcEvents.reasonOf('IO_ERROR'), 'reset');
      expect(ColituAcEvents.reasonOf('NETWORK_ERROR'), 'no_network');
      expect(ColituAcEvents.reasonOf('VERIFY_FAILED'), 'blocked');
      expect(ColituAcEvents.reasonOf('ENGINE_FAILED'), 'core_crash');
      expect(ColituAcEvents.reasonOf('FREE_DAILY_LIMIT_REACHED'), 'quota');
      expect(ColituAcEvents.reasonOf('NETWORK_CHANGE'), 'network_change');
      expect(ColituAcEvents.reasonOf('whatever'), 'other');
      expect(ColituAcEvents.reasonOf(null), 'other');
    });
  });

  group('event builders', () {
    test('connect: ok has no reason, a failure does; node is lower-cased', () {
      final ok = ColituAcEvents.connect(
        nodeId: _n1.toUpperCase(),
        protocol: 'Hysteria2',
        ok: true,
        ms: 1234,
        firstTry: true,
        auto: true,
      );
      expect(ok, {
        'kind': 'connect',
        'node_id': _n1,
        'protocol': 'hysteria2',
        'outcome': 'ok',
        'ms': 1234,
        'first_try': true,
        'mode': 'auto',
      });
      final fail = ColituAcEvents.connect(
        nodeId: _n1,
        protocol: 'trojan',
        ok: false,
        code: 'VERIFY_FAILED',
        ms: 9999999,
        firstTry: false,
        auto: false,
      )!;
      expect(fail['reason'], 'blocked');
      expect(fail['ms'], 600000, reason: 'capped at ten minutes');
      expect(fail['mode'], 'manual');
    });

    test('a missing or unknown node or protocol builds nothing', () {
      expect(
        ColituAcEvents.connect(nodeId: null, protocol: 'trojan', ok: true, ms: 1, firstTry: true, auto: true),
        isNull,
      );
      expect(
        ColituAcEvents.connect(nodeId: 'short', protocol: 'trojan', ok: true, ms: 1, firstTry: true, auto: true),
        isNull,
      );
      expect(
        ColituAcEvents.connect(nodeId: _n1, protocol: 'wireguard', ok: true, ms: 1, firstTry: true, auto: true),
        isNull,
      );
    });

    test('recovery, switch, drop, probe', () {
      expect(
        ColituAcEvents.recovery(
          nodeId: _n1,
          protocol: 'hysteria2',
          toProtocol: 'vless-reality',
          ok: true,
          ms: 4000,
          detectMs: 15000,
          spare: true,
        ),
        {
          'kind': 'recovery',
          'node_id': _n1,
          'protocol': 'hysteria2',
          'to_protocol': 'vless-reality',
          'outcome': 'ok',
          'ms': 4000,
          'detect_ms': 15000,
          'spare': true,
        },
      );
      expect(
        ColituAcEvents.switched(from: 'hysteria2', to: null, ok: false, flap: false),
        isNull,
      );
      expect(
        ColituAcEvents.switched(from: 'hysteria2', to: 'hysteria2', ok: false, flap: false),
        {'kind': 'switch', 'protocol': 'hysteria2', 'to_protocol': 'hysteria2', 'outcome': 'fail', 'flap': false},
      );
      expect(
        ColituAcEvents.drop(nodeId: _n1, protocol: 'trojan', code: 'other', minutes: 12),
        {'kind': 'drop', 'node_id': _n1, 'protocol': 'trojan', 'reason': 'other', 'minutes': 12},
      );
      expect(ColituAcEvents.probe(_n1, 42), {'kind': 'probe', 'node_id': _n1, 'outcome': 'ok', 'ms': 42});
      expect(ColituAcEvents.probe(_n1, null), {'kind': 'probe', 'node_id': _n1, 'outcome': 'fail'});
    });

    test('choice: best_ms never exceeds ms', () {
      expect(
        ColituAcEvents.choice(_n1, {_n1: 80, _n2: 20}),
        {
          'kind': 'choice',
          'node_id': _n1,
          'ms': 80,
          'best_node_id': _n2,
          'best_ms': 20,
          'mode': 'auto',
        },
      );
      final chosenBest = ColituAcEvents.choice(_n1, {_n1: 20, _n2: 80})!;
      expect(chosenBest['best_node_id'], _n1);
      expect(chosenBest['best_ms'], 20);
      // The chosen node has no measurement: nothing to compare.
      expect(ColituAcEvents.choice(_n1, {_n1: null, _n2: 20}), isNull);
      expect(ColituAcEvents.choice(_n1, {}), isNull);
    });

    test('network type is one of four, else empty', () {
      expect(ColituAcEvents.networkTypeOf('WiFi'), 'wifi');
      expect(ColituAcEvents.networkTypeOf('cellular'), 'cellular');
      expect(ColituAcEvents.networkTypeOf('ethernet'), 'ethernet');
      expect(ColituAcEvents.networkTypeOf('other'), 'other');
      expect(ColituAcEvents.networkTypeOf('none'), '');
      expect(ColituAcEvents.networkTypeOf(null), '');
    });
  });

  group('queue', () {
    Map<String, dynamic> ev(int i) => {'kind': 'connect', 'i': i};

    test('is capped at 1000; the oldest events go first', () {
      final q = AcQueue();
      for (var i = 0; i < 1100; i++) {
        q.add(ev(i), 't', 'wifi', i);
      }
      expect(q.entries, hasLength(1000));
      expect(q.entries.first.event['i'], 100);
      expect(q.entries.last.event['i'], 1099);
    });

    test('a batch is at most 300 events of the oldest event\'s network', () {
      final q = AcQueue();
      q.add(ev(0), 'a', 'wifi', 0);
      for (var i = 1; i <= 400; i++) {
        q.add(ev(i), 'a', 'wifi', i);
      }
      q.add(ev(999), 'b', 'cellular', 999);
      final batch = q.nextBatch();
      expect(batch, hasLength(300));
      expect(batch.every((e) => e.token == 'a'), isTrue);
      expect(batch.first.event['i'], 0);
      q.remove(batch);
      expect(q.entries, hasLength(102));
      expect(q.nextBatch().length, 101);
      q.remove(q.nextBatch());
      expect(q.nextBatch().single.token, 'b');
    });

    test('only the last probe of a node per hour is kept', () {
      final q = AcQueue();
      final t = DateTime(2026, 10, 11).millisecondsSinceEpoch;
      q.add({'kind': 'probe', 'node_id': _n1, 'ms': 10}, '', 'wifi', t);
      q.add({'kind': 'probe', 'node_id': _n2, 'ms': 10}, '', 'wifi', t + 1000);
      q.add({'kind': 'probe', 'node_id': _n1, 'ms': 30}, '', 'wifi', t + 60000);
      expect(q.entries.map((e) => e.event['ms']), [10, 30]);
      expect(q.entries.map((e) => e.event['node_id']), [_n2, _n1]);
      // A probe from more than an hour ago stays.
      q.add({'kind': 'probe', 'node_id': _n1, 'ms': 50}, '', 'wifi', t + 2 * 3600 * 1000);
      expect(q.entries, hasLength(3));
    });

    test('storage round-trips and applies the cap', () {
      final q = AcQueue();
      for (var i = 0; i < 5; i++) {
        q.add(ev(i), 'tok', 'wifi', i);
      }
      final back = AcQueue.decode(q.encode(), cap: 3);
      expect(back.entries.map((e) => e.event['i']), [2, 3, 4]);
      expect(back.entries.first.token, 'tok');
      expect(back.entries.first.type, 'wifi');
      expect(AcQueue.decode('nope').isEmpty, isTrue);
    });

    test('request body', () {
      final q = AcQueue()..add(ev(1), 'tok', 'cellular', 1);
      final body = ColituAcEvents.requestBody('5.8.1', 'tok', 'cellular', q.nextBatch());
      expect(body, {
        'platform': 'ios',
        'app_version': '5.8.1',
        'network_token': 'tok',
        'network_type': 'cellular',
        'events': [
          {'kind': 'connect', 'i': 1},
        ],
      });
      expect(
        ColituAcEvents.requestBody('1', '', '', const [])['network_type'],
        '',
      );
    });
  });

  group('ColituAcEventStore', () {
    late _MemoryKv kv;
    late _MemoryKv metricsKv;
    late DateTime now;
    late List<Map<String, dynamic>> posts;
    Object? failWith;
    late ColituMetrics metrics;

    ColituAcEventStore make() => ColituAcEventStore(
      metrics: metrics,
      store: kv,
      clock: () => now,
      appVersion: () async => '5.8.1',
      post: (path, body) async {
        expect(path, '/client/ac-events');
        posts.add(body);
        if (failWith != null) throw failWith!;
      },
    );

    setUp(() {
      kv = _MemoryKv();
      metricsKv = _MemoryKv();
      now = DateTime(2026, 10, 11, 12);
      posts = [];
      failWith = null;
      metrics = ColituMetrics(store: metricsKv, clock: () => now);
    });

    Map<String, dynamic> connectEvent() => ColituAcEvents.connect(
      nodeId: _n1,
      protocol: 'trojan',
      ok: true,
      ms: 10,
      firstTry: true,
      auto: true,
    )!;

    test('sends hourly, per network, and clears what was accepted', () async {
      final s = make();
      s.record(connectEvent(), token: 'a', linkType: 'wifi');
      s.record(connectEvent(), token: 'b', linkType: 'cellular');
      await s.maybeSend();
      expect(posts.map((p) => p['network_token']), ['a', 'b']);
      expect(await s.length(), 0);
      s.record(connectEvent(), token: 'a', linkType: 'wifi');
      await s.maybeSend();
      expect(posts, hasLength(2), reason: 'less than an hour since the last try');
      now = now.add(const Duration(hours: 1));
      await s.maybeSend();
      expect(posts, hasLength(3));
    });

    test('a refused or lost send keeps the events; 400 drops them', () async {
      failWith = APIException(APIErrorCode.unknown, 'x', statusCode: 429);
      var s = make();
      s.record(connectEvent(), token: '', linkType: 'wifi');
      await s.maybeSend();
      expect(await s.length(), 1);
      failWith = APIException(APIErrorCode.unknown, 'x', statusCode: 400);
      now = now.add(const Duration(hours: 2));
      await s.maybeSend();
      expect(await s.length(), 0);
      s = make();
      expect(await s.length(), 0);
    });

    test('nothing is queued while the statistics switch is off, and the queue is emptied', () async {
      final s = make();
      s.record(connectEvent(), token: '', linkType: 'wifi');
      expect(await s.length(), 1);
      await metrics.setEnabled(false);
      await s.idle();
      expect(await s.length(), 0, reason: 'turning it off clears the queue');
      s.record(connectEvent(), token: '', linkType: 'wifi');
      expect(await s.length(), 0);
      await s.maybeSend();
      expect(posts, isEmpty);
    });
  });

  group('ColituTelemetry', () {
    late _MemoryKv kv;
    late DateTime now;
    late ColituMetrics metrics;
    late ColituAcEventStore events;
    late ColituTelemetry t;

    setUp(() {
      kv = _MemoryKv();
      now = DateTime(2026, 10, 11, 12);
      metrics = ColituMetrics(store: kv, clock: () => now);
      events = ColituAcEventStore(metrics: metrics, store: kv, clock: () => now);
      t = ColituTelemetry(
        metrics: metrics,
        events: events,
        clock: () => now,
        tokenOf: () => 'tok',
        linkOf: () => 'wifi',
        isNode: (id) => id == _n1 || id == _n2,
      );
    });

    Future<List<Map<String, dynamic>>> queued() async {
      await metrics.idle();
      await events.idle();
      return events.snapshotEvents();
    }

    test('a successful connect: counters, histogram, first-connect and one event', () async {
      final id = t.beginConnect(auto: true);
      await metrics.idle();
      t.tryingConnect(nodeId: _n1, protocol: 'hysteria2', fallbacks: 0);
      now = now.add(const Duration(milliseconds: 2500));
      // endConnect counts the functional check (once per connect).
      t.endConnect(ok: true, nodeId: _n1, protocol: 'hysteria2', id: id);
      final snap = await metrics.snapshot();
      expect(snap.counters, {
        'connect_attempts': 1,
        'first_connect_attempts': 1,
        'connect_successes': 1,
        'first_connect_successes': 1,
        'sessions': 1,
        'functional_checks': 1,
        'functional_ok': 1,
      });
      expect(snap.histograms['connect_ms'], [0, 0, 0, 1, 0, 0, 0, 0, 0]);
      final list = await queued();
      expect(list, hasLength(1));
      expect(list.single['kind'], 'connect');
      expect(list.single['outcome'], 'ok');
      expect(list.single['first_try'], isTrue);
      expect(list.single['mode'], 'auto');
      expect(list.single['ms'], 2500);
      // The next connect is not the first any more.
      t.beginConnect(auto: false);
      await metrics.idle();
      expect((await metrics.snapshot()).counters['first_connect_attempts'], 1);
    });

    test('a failed connect names the reason and the server it fell back to', () async {
      final id = t.beginConnect(auto: false);
      await metrics.idle();
      t.tryingConnect(nodeId: _n2, protocol: 'trojan', fallbacks: 1);
      t.endConnect(ok: false, reason: 'timeout', id: id);
      final snap = await metrics.snapshot();
      expect(snap.counters.containsKey('connect_successes'), isFalse);
      expect(snap.counters['connect_attempts'], 1);
      final e = (await queued()).single;
      expect(e['outcome'], 'fail');
      expect(e['reason'], 'timeout');
      expect(e['first_try'], isFalse);
      expect(e['mode'], 'manual');
      expect(e['node_id'], _n2);
    });

    test('an abandoned attempt is taken back, a stale id cannot close a newer one', () async {
      final first = t.beginConnect(auto: true);
      await metrics.idle();
      final second = t.beginConnect(auto: true);
      await metrics.idle();
      // The first attempt was replaced: counted once.
      expect((await metrics.snapshot()).counters['connect_attempts'], 1);
      expect(t.isCurrentAttempt(first), isFalse);
      t.endConnect(ok: false, reason: 'other', id: first);
      t.abandonConnect(id: first);
      expect(t.isCurrentAttempt(second), isTrue);
      t.abandonConnect(id: second);
      await metrics.idle();
      expect((await metrics.snapshot()).isEmpty, isTrue);
      expect(await queued(), isEmpty);
    });

    test('a multihop route (no node id) counts but sends no event', () async {
      final id = t.beginConnect(auto: false);
      await metrics.idle();
      t.endConnect(ok: true, nodeId: null, protocol: 'vless-reality', id: id);
      expect((await metrics.snapshot()).counters['sessions'], 1);
      expect(await queued(), isEmpty);
    });

    test('recovery with a protocol switch, then a flap back within two minutes', () async {
      t.beginRecovery(
        failedAt: now.subtract(const Duration(seconds: 20)),
        protocol: 'hysteria2',
        nodeId: _n1,
        failedProtocol: 'hysteria2',
        detectMs: 15000,
        spare: true,
      );
      now = now.add(const Duration(seconds: 5));
      t.endRecovery(ok: true, newProtocol: 'trojan');
      t.beginRecovery(
        failedAt: now,
        protocol: 'trojan',
        nodeId: _n1,
        failedProtocol: 'trojan',
      );
      now = now.add(const Duration(seconds: 30));
      t.endRecovery(ok: true, newProtocol: 'hysteria2');
      final snap = await metrics.snapshot();
      expect(snap.counters, {
        'recoveries': 2,
        'protocol_switches': 2,
        'recovery_successes': 2,
        'protocol_switch_successes': 2,
        'flaps': 1,
      });
      expect(snap.histograms.keys.toSet(), {'detection_ms', 'recovery_ms'});
      final list = await queued();
      expect(list.map((e) => e['kind']), ['recovery', 'switch', 'recovery', 'switch']);
      expect(list[0]['detect_ms'], 15000);
      expect(list[0]['spare'], isTrue);
      expect(list[0]['to_protocol'], 'trojan');
      expect(list[1]['flap'], isFalse);
      expect(list[3]['flap'], isTrue);
    });

    test('a second begin while a recovery is open changes nothing', () async {
      t.beginRecovery(
        failedAt: now.subtract(const Duration(seconds: 10)),
        protocol: 'hysteria2',
        nodeId: _n1,
      );
      t.beginRecovery(failedAt: now, protocol: 'trojan', nodeId: _n1);
      t.beginRecovery(failedAt: now, nodeId: _n1);
      expect((await metrics.snapshot()).isEmpty, isTrue);
      now = now.add(const Duration(seconds: 5));
      t.endRecovery(ok: false);
      final snap = await metrics.snapshot();
      expect(snap.counters, {'recoveries': 1, 'protocol_switches': 1});
      final list = await queued();
      // No switch event: the recovery reached no protocol.
      expect(list.map((e) => e['kind']), ['recovery']);
      expect(list[0]['ms'], 15000);
      expect(list[0]['protocol'], 'hysteria2');
    });

    test('an abandoned recovery counts nothing', () async {
      t.beginRecovery(failedAt: now, protocol: 'hysteria2', nodeId: _n1);
      t.abandonRecovery();
      t.endRecovery(ok: true, newProtocol: 'trojan');
      expect((await metrics.snapshot()).counters, isEmpty);
      expect(await queued(), isEmpty);
    });

    test('an unexpected drop counts and sends a drop event with the minutes up', () async {
      final id = t.beginConnect(auto: true);
      await metrics.idle();
      t.endConnect(ok: true, nodeId: _n1, protocol: 'trojan', id: id);
      now = now.add(const Duration(minutes: 7));
      final up = t.unexpectedDrop();
      expect(up.node, _n1);
      expect(up.protocol, 'trojan');
      final list = await queued();
      expect(list.last['kind'], 'drop');
      expect(list.last['minutes'], 7);
      expect(list.last['reason'], 'other');
      expect((await metrics.snapshot()).counters['unexpected_disconnects'], 1);
    });

    test('probe and choice events', () async {
      t.probe(_n1, 35);
      t.probe(_n2, null);
      t.choice(_n1, {_n1: 35, _n2: 20});
      final list = await queued();
      expect(list.map((e) => e['kind']), ['probe', 'probe', 'choice']);
      expect(list.last['best_node_id'], _n2);
    });

    test('with the switch off nothing is recorded', () async {
      await t.setStatisticsEnabled(false);
      final id = t.beginConnect(auto: true);
      t.endConnect(ok: true, nodeId: _n1, protocol: 'trojan', id: id);
      t.probe(_n1, 10);
      expect((await metrics.snapshot()).isEmpty, isTrue);
      expect(await queued(), isEmpty);
    });
  });
}
