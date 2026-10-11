import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';
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

APIException _http(int status) =>
    APIException(APIErrorCode.unknown, 'x', statusCode: status);

void main() {
  group('histogram buckets', () {
    test('the first bound a value does not exceed, else the open last one', () {
      expect(ColituMetricsData.bucketOf(0), 0);
      expect(ColituMetricsData.bucketOf(500), 0);
      expect(ColituMetricsData.bucketOf(501), 1);
      expect(ColituMetricsData.bucketOf(1000), 1);
      expect(ColituMetricsData.bucketOf(2000), 2);
      expect(ColituMetricsData.bucketOf(3000), 3);
      expect(ColituMetricsData.bucketOf(5000), 4);
      expect(ColituMetricsData.bucketOf(8000), 5);
      expect(ColituMetricsData.bucketOf(15000), 6);
      expect(ColituMetricsData.bucketOf(30000), 7);
      expect(ColituMetricsData.bucketOf(30001), 8);
      expect(ColituMetricsData.bucketOf(10 * 60 * 1000), 8);
    });

    test('observe fills nine buckets and ignores unknown names', () {
      final d = ColituMetricsData()
        ..observe('connect_ms', 400)
        ..observe('connect_ms', 450)
        ..observe('connect_ms', 9000)
        ..observe('connect_ms', 99999)
        ..observe('nope_ms', 10)
        ..observe('connect_ms', -5);
      expect(d.histograms.keys, ['connect_ms']);
      expect(d.histograms['connect_ms'], [2, 0, 0, 0, 0, 0, 1, 0, 1]);
    });
  });

  group('counters', () {
    test('only known counters; capped at 10000; never below zero', () {
      final d = ColituMetricsData()
        ..add('connect_attempts', 9990)
        ..add('connect_attempts', 50)
        ..add('unknown_counter')
        ..add('sessions', -3);
      expect(d.counters, {'connect_attempts': 10000});
      d.add('connect_attempts', -10000);
      expect(d.counters, isEmpty);
    });

    test('a taken-back attempt removes a zero counter', () {
      final d = ColituMetricsData()
        ..add('connect_attempts')
        ..add('connect_attempts', -1);
      expect(d.counters, isEmpty);
    });

    test('subtract removes what was sent and keeps what came later', () {
      final d = ColituMetricsData()
        ..add('connect_attempts', 3)
        ..observe('connect_ms', 100)
        ..feature('shield');
      final sent = d.copy();
      d
        ..add('connect_attempts', 2)
        ..observe('connect_ms', 100)
        ..feature('ad_block');
      d.subtract(sent);
      expect(d.counters, {'connect_attempts': 2});
      expect(d.histograms['connect_ms']![0], 1);
      expect(d.features, {'ad_block'});
      d.subtract(d.copy());
      expect(d.isEmpty, isTrue);
    });

    test('storage round-trips and survives garbage', () {
      final d = ColituMetricsData()
        ..add('sessions', 4)
        ..observe('recovery_ms', 2500)
        ..feature('multihop');
      final back = ColituMetricsData.decode(d.encode());
      expect(back.counters, {'sessions': 4});
      expect(back.histograms['recovery_ms']![3], 1);
      expect(back.features, {'multihop'});
      expect(ColituMetricsData.decode('not json').isEmpty, isTrue);
      expect(ColituMetricsData.decode(null).isEmpty, isTrue);
    });
  });

  group('request JSON', () {
    test('platform ios, non-zero counters, filled histograms, features', () {
      final d = ColituMetricsData()
        ..add('connect_attempts', 5)
        ..add('connect_successes', 4)
        ..observe('connect_ms', 700)
        ..feature('split_tunnel')
        ..feature('auto_connect')
        ..feature('custom_dns');
      expect(d.toRequest('5.8.1', killSwitch: true), {
        'platform': 'ios',
        'app_version': '5.8.1',
        'counters': {'connect_attempts': 5, 'connect_successes': 4},
        'histograms': {
          'connect_ms': [0, 1, 0, 0, 0, 0, 0, 0, 0],
        },
        'kill_switch': true,
        'features': ['auto_connect', 'custom_dns', 'split_tunnel'],
      });
    });

    test('an empty report still has the four sections', () {
      expect(ColituMetricsData().toRequest('1.0.0', killSwitch: false), {
        'platform': 'ios',
        'app_version': '1.0.0',
        'counters': <String, int>{},
        'histograms': <String, List<int>>{},
        'kill_switch': false,
        'features': <String>[],
      });
    });
  });

  group('send rules', () {
    test('202 resets, 400 drops, 429 / 5xx / no answer keep', () {
      expect(colituOutcomeFor(202), ColituMetricsOutcome.reset);
      expect(colituOutcomeFor(200), ColituMetricsOutcome.reset);
      expect(colituOutcomeFor(400), ColituMetricsOutcome.reset);
      expect(colituOutcomeFor(429), ColituMetricsOutcome.keep);
      expect(colituOutcomeFor(500), ColituMetricsOutcome.keep);
      expect(colituOutcomeFor(503), ColituMetricsOutcome.keep);
      expect(colituOutcomeFor(401), ColituMetricsOutcome.keep);
      expect(colituOutcomeFor(null), ColituMetricsOutcome.keep);
    });

    test('due: enabled, data, and 6 h since the last try', () {
      final now = DateTime(2026, 10, 11, 12);
      bool due({bool enabled = true, bool data = true, DateTime? last}) =>
          ColituMetricsRules.due(
            enabled: enabled,
            hasData: data,
            lastAttempt: last,
            now: now,
          );
      expect(due(), isTrue);
      expect(due(enabled: false), isFalse);
      expect(due(data: false), isFalse);
      expect(due(last: now.subtract(const Duration(hours: 5, minutes: 59))), isFalse);
      expect(due(last: now.subtract(const Duration(hours: 6))), isTrue);
      // A clock set back allows one.
      expect(due(last: now.add(const Duration(hours: 1))), isTrue);
    });

    test('a flap undoes the previous switch within two minutes', () {
      final t = DateTime(2026, 10, 11, 12);
      final last = (from: 'hysteria2', to: 'trojan', at: t);
      expect(
        ColituMetricsRules.isFlap(last, 'trojan', 'hysteria2', t.add(const Duration(seconds: 90))),
        isTrue,
      );
      expect(
        ColituMetricsRules.isFlap(last, 'trojan', 'hysteria2', t.add(const Duration(minutes: 3))),
        isFalse,
      );
      expect(
        ColituMetricsRules.isFlap(last, 'trojan', 'vless-reality', t.add(const Duration(seconds: 10))),
        isFalse,
      );
      expect(ColituMetricsRules.isFlap(null, 'a', 'b', t), isFalse);
    });
  });

  group('ColituMetrics store', () {
    late _MemoryKv kv;
    late DateTime now;
    late List<Map<String, dynamic>> posts;
    Object? failWith;

    ColituMetrics make() => ColituMetrics(
      store: kv,
      clock: () => now,
      appVersion: () async => '5.8.1',
      post: (path, body) async {
        expect(path, '/client/metrics');
        posts.add(body);
        if (failWith != null) throw failWith!;
      },
    );

    setUp(() {
      kv = _MemoryKv();
      now = DateTime(2026, 10, 11, 12);
      posts = [];
      failWith = null;
    });

    test('collects, sends once, then waits six hours', () async {
      final m = make();
      m.count('connect_attempts');
      m.count('connect_successes');
      m.observe('connect_ms', 1200);
      m.features(['shield']);
      await m.maybeSend(killSwitch: false);
      expect(posts, hasLength(1));
      expect(posts.single['counters'], {'connect_attempts': 1, 'connect_successes': 1});
      expect(posts.single['features'], ['shield']);
      expect((await m.snapshot()).isEmpty, isTrue);

      m.count('sessions');
      await m.maybeSend(killSwitch: false);
      expect(posts, hasLength(1), reason: 'less than 6 h since the last try');
      now = now.add(const Duration(hours: 6));
      await m.maybeSend(killSwitch: true);
      expect(posts, hasLength(2));
      expect(posts.last['kill_switch'], isTrue);
      expect(posts.last['features'], ['kill_switch']);
    });

    test('429, 5xx and a lost connection keep the numbers', () async {
      for (final error in [_http(429), _http(503), const APIException(APIErrorCode.networkUnavailable, 'offline')]) {
        kv = _MemoryKv();
        failWith = error;
        posts = [];
        final m = make();
        m.count('sessions', 2);
        await m.maybeSend(killSwitch: false);
        expect(posts, hasLength(1));
        expect((await m.snapshot()).counters, {'sessions': 2}, reason: '$error');
      }
    });

    test('400 drops the numbers (they would never be accepted)', () async {
      failWith = _http(400);
      final m = make();
      m.count('sessions', 2);
      await m.maybeSend(killSwitch: false);
      expect((await m.snapshot()).isEmpty, isTrue);
    });

    test('counts added while a report is on its way are kept', () async {
      final m = ColituMetrics(
        store: kv,
        clock: () => now,
        appVersion: () async => '5.8.1',
        post: (path, body) async {
          // Recorded after the snapshot was taken.
          posts.add(body);
        },
      );
      m.count('sessions', 2);
      await m.maybeSend(killSwitch: false);
      m.count('sessions');
      expect((await m.snapshot()).counters, {'sessions': 1});
    });

    test('turning the switch off deletes everything and stops collecting', () async {
      var disabledCalled = false;
      final m = make()..onDisabled = () => disabledCalled = true;
      m.count('connect_attempts', 3);
      m.observe('connect_ms', 10);
      await m.idle();
      expect(kv.map.containsKey('colituMetricsData'), isTrue);
      await m.setEnabled(false);
      expect(disabledCalled, isTrue);
      expect(await m.isEnabled(), isFalse);
      expect(kv.map.containsKey('colituMetricsData'), isFalse);
      m.count('connect_attempts');
      await m.maybeSend(killSwitch: false);
      expect((await m.snapshot()).isEmpty, isTrue);
      expect(posts, isEmpty);
      await m.setEnabled(true);
      m.count('connect_attempts');
      expect((await m.snapshot()).counters, {'connect_attempts': 1});
    });

    test('the first-connect flag is set once', () async {
      final m = make();
      expect(await m.isFirstConnect(), isTrue);
      await m.markFirstDone();
      expect(await m.isFirstConnect(), isFalse);
      expect(await make().isFirstConnect(), isFalse);
    });

    test('the state survives a restart', () async {
      final a = make();
      a.count('sessions', 7);
      await a.idle();
      final b = make();
      expect((await b.snapshot()).counters, {'sessions': 7});
    });
  });
}
