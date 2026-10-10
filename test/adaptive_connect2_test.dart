import 'dart:convert';

import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/stall_watch.dart';
import 'package:colitu_vpn/colitu/services/warm_spare.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:colitu_vpn/service/xray/setting/state_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adaptive Connect 2.0 (port of Android's final behaviour), rules 2–9.
void main() {
  final t0 = DateTime(2026, 10, 10, 12);
  const net = 'cellular|RU-AS1';

  group('rule 2: mid-session watcher on every transport', () {
    test('every 5 s for the first 90 s, then every 30 s', () {
      final watch = ColituStallWatch()..startSession(t0);
      expect(watch.intervalAt(t0.add(const Duration(seconds: 89))), const Duration(seconds: 5));
      expect(watch.intervalAt(t0.add(const Duration(seconds: 90))), const Duration(seconds: 30));
      watch.begin(t0.add(const Duration(seconds: 100)), 0);
      watch.finish(ok: true, hasNetwork: true, now: t0.add(const Duration(seconds: 100)));
      expect(watch.due(t0.add(const Duration(seconds: 120))), isFalse);
      expect(watch.due(t0.add(const Duration(seconds: 130))), isTrue);
    });

    test('3 misses while online = primary dead; offline misses do not count', () {
      final watch = ColituStallWatch()..startSession(t0);
      bool miss(int s, {bool online = true}) {
        final at = t0.add(Duration(seconds: s));
        watch.begin(at, 0);
        return watch.finish(ok: false, hasNetwork: online, now: at);
      }

      expect(miss(5), isFalse);
      expect(miss(10, online: false), isFalse);
      expect(miss(15), isFalse);
      expect(miss(20), isFalse);
      expect(miss(25), isTrue);
    });
  });

  group('rule 3: spare-aware watcher', () {
    test('primary dead + normal path ok: no reconnect, the spare carries', () {
      expect(
        ColituStallWatch.decide(primaryDead: true, spareAttached: true, normalOk: true),
        ColituWatchAction.spareCarries,
      );
      expect(
        ColituStallWatch.decide(primaryDead: true, spareAttached: true, normalOk: false),
        ColituWatchAction.reconnect,
      );
      expect(
        ColituStallWatch.decide(primaryDead: true, spareAttached: false, normalOk: true),
        ColituWatchAction.reconnect,
      );
      expect(
        ColituStallWatch.decide(primaryDead: false, spareAttached: true, normalOk: false),
        ColituWatchAction.none,
      );
    });

    test('the spare becomes the remembered good path and leads next time', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(net, 'de', 'hysteria2', t0)
        ..markStalled(net, 'de', 'hysteria2', t0)
        ..recordSuccess(net, 'fi', 'vless-reality', t0);
      expect(memory.lastGoodServer(net, t0), 'fi');
      expect(memory.lastGoodTransport(net, 'fi', t0), 'vless-reality');
      // Another transport carried traffic: the primary's mark lasts 6 h.
      expect(
        memory.stalledTransports(net, 'de', t0.add(const Duration(hours: 5))),
        {'hysteria2'},
      );
    });
  });

  group('rule 4: stall marks cannot lock a network', () {
    test('marks leaving at most one transport are ignored for the round', () {
      final r = colituStallMarks(
        ['hysteria2', 'vless-reality', 'trojan'],
        {'hysteria2', 'vless-reality'},
      );
      expect(r.hard, isEmpty);
      expect(r.soft, {'hysteria2', 'vless-reality'});
      final ok = colituStallMarks(
        ['hysteria2', 'vless-reality', 'trojan'],
        {'hysteria2'},
      );
      expect(ok.hard, {'hysteria2'});
      expect(ok.soft, isEmpty);
    });

    test('order: proven first, then unmarked, then ignored marks, then hard', () {
      int rank(String p) => ColituVPNConfigAdapter.transportRankFor(
        p,
        excluded: const {'shadowsocks'},
        soft: const {'hysteria2'},
        prefer: 'trojan',
      );
      final order = ['hysteria2', 'vless-reality', 'trojan', 'shadowsocks']
        ..sort((a, b) => rank(a).compareTo(rank(b)));
      expect(order, ['trojan', 'vless-reality', 'hysteria2', 'shadowsocks']);
    });

    test('a failing-round mark lasts 10 min unless another transport works', () {
      final memory = ColituAdaptiveMemory()..markStalled(net, 'de', 'hysteria2', t0);
      final later = t0.add(const Duration(minutes: 11));
      expect(memory.stalledTransports(net, 'de', t0), {'hysteria2'});
      expect(memory.stalledTransports(net, 'de', later), isEmpty);

      final promoted = ColituAdaptiveMemory()
        ..markStalled(net, 'de', 'hysteria2', t0)
        ..recordSuccess(net, 'de', 'vless-reality', t0);
      expect(promoted.stalledTransports(net, 'de', later), {'hysteria2'});
    });
  });

  group('rule 5: spare choice', () {
    const all = ['hysteria2', 'vless-reality', 'vless-xhttp', 'trojan', 'shadowsocks'];

    test('automatic: a proven transport on the next server, own one first', () {
      final d = ColituWarmSpare.decide(
        sameServer: false,
        primaryProtocol: 'vless-reality',
        offered: all,
        proven: const {'vless-reality', 'trojan'},
      )!;
      expect((d.protocol, d.reason), ('vless-reality', 'proven'));
    });

    test('automatic: nothing proven -> the other family', () {
      final d = ColituWarmSpare.decide(
        sameServer: false,
        primaryProtocol: 'hysteria2',
        offered: all,
      )!;
      expect((d.protocol, d.reason), ('vless-reality', 'other-family'));
      final same = ColituWarmSpare.decide(
        sameServer: false,
        primaryProtocol: 'hysteria2',
        offered: const ['hysteria2'],
      )!;
      expect((same.protocol, same.reason), ('hysteria2', 'same-transport'));
    });

    test('manual: same server, other family, never its own, SS last', () {
      final d = ColituWarmSpare.decide(
        sameServer: true,
        primaryProtocol: 'vless-reality',
        offered: all,
        stalled: const {'hysteria2'},
      )!;
      expect(d.protocol, 'vless-xhttp');
      final ss = ColituWarmSpare.decide(
        sameServer: true,
        primaryProtocol: 'vless-reality',
        offered: const ['vless-reality', 'shadowsocks', 'trojan'],
      )!;
      expect(ss.protocol, 'trojan');
      expect(
        ColituWarmSpare.decide(
          sameServer: true,
          primaryProtocol: 'trojan',
          offered: const ['trojan'],
        ),
        isNull,
      );
    });

    test('hinted-blocked only when nothing else; avoided never', () {
      final d = ColituWarmSpare.decide(
        sameServer: true,
        primaryProtocol: 'vless-reality',
        offered: const ['vless-reality', 'hysteria2'],
        hinted: const {'hysteria2'},
      )!;
      expect((d.protocol, d.reason), ('hysteria2', 'hinted-fallback'));
      expect(
        ColituWarmSpare.decide(
          sameServer: true,
          primaryProtocol: 'vless-reality',
          offered: const ['vless-reality', 'hysteria2'],
          avoid: const {'hysteria2'},
        ),
        isNull,
      );
    });

    test('proven = carried traffic on this network in 24 h, any server', () {
      final memory = ColituAdaptiveMemory()
        ..recordSuccess(net, 'de', 'trojan', t0)
        ..recordSuccess(net, 'fi', 'hysteria2', t0);
      expect(memory.provenTransports(net, t0), {'trojan', 'hysteria2'});
      expect(
        memory.provenTransports(net, t0.add(const Duration(hours: 25))),
        isEmpty,
      );
    });
  });

  group('rule 7: spare health probe', () {
    test('60 s for a UDP spare, 180 s for a TCP spare', () {
      final watch = ColituSpareWatch()..reset(t0);
      expect(watch.due(t0.add(const Duration(seconds: 59)), 'hysteria2'), isFalse);
      expect(watch.due(t0.add(const Duration(seconds: 60)), 'hysteria2'), isTrue);
      expect(watch.due(t0.add(const Duration(seconds: 179)), 'trojan'), isFalse);
      expect(watch.due(t0.add(const Duration(seconds: 180)), 'trojan'), isTrue);
    });

    test('two misses while online -> dead (replacement); offline does not count', () {
      final watch = ColituSpareWatch()..reset(t0);
      expect(watch.finish(ok: false, online: true), isFalse);
      expect(watch.finish(ok: false, online: false), isFalse);
      expect(watch.finish(ok: false, online: true), isTrue);
      watch.reset(t0);
      expect(watch.finish(ok: false, online: true), isFalse);
      expect(watch.finish(ok: true, online: true), isFalse);
      expect(watch.finish(ok: false, online: true), isFalse);
    });

    test('a swap waits while the tunnel is busy (>= 10 KB in 10 s)', () {
      expect(ColituSpareWatch.swapAllowed(9 * 1024), isTrue);
      expect(ColituSpareWatch.swapAllowed(10 * 1024), isFalse);
    });

    test('the replacement skips the dead spare server and transport', () {
      final d = ColituWarmSpare.decide(
        sameServer: true,
        primaryProtocol: 'hysteria2',
        offered: const ['hysteria2', 'vless-reality', 'trojan'],
        avoid: const {'vless-reality'},
      )!;
      expect(d.protocol, 'trojan');
    });
  });

  group('rule 8: parallel connect round', () {
    Future<bool> after(int ms, bool ok) =>
        Future.delayed(Duration(milliseconds: ms), () => ok);
    const grace = Duration(milliseconds: 200);

    test('primary passes -> primary wins at once', () async {
      final r = await colituParallelRound(
        primary: () => after(20, true),
        spare: () => after(5, true),
        grace: grace,
      );
      expect(r.winner, ColituRoundWinner.primary);
    });

    test('only the spare passes -> spare after the grace (role swap)', () async {
      final r = await colituParallelRound(
        primary: () => after(1000, false),
        spare: () => after(5, true),
        grace: grace,
      );
      expect(r.winner, ColituRoundWinner.spare);
      expect(r.elapsed, lessThan(const Duration(milliseconds: 900)));
    });

    test('the primary passing within the grace still wins', () async {
      final r = await colituParallelRound(
        primary: () => after(80, true),
        spare: () => after(5, true),
        grace: grace,
      );
      expect(r.winner, ColituRoundWinner.primary);
    });

    test('both fail -> none (next pair)', () async {
      final r = await colituParallelRound(
        primary: () => after(10, false),
        spare: () => after(20, false),
        grace: grace,
      );
      expect(r.winner, ColituRoundWinner.none);
    });

    test('a swapped plan keeps the new primary and a different spare', () {
      const plan = ColituSpareChoice(
        configId: 3,
        server: 'fi',
        protocol: 'trojan',
        outbound: {'protocol': 'trojan'},
        reason: 'other-family',
        primary: ColituPath(
          server: 'de',
          protocol: 'vless-reality',
          outbound: {'protocol': 'vless'},
        ),
      );
      final back = ColituSpareChoice.fromJson(jsonDecode(jsonEncode(plan.toJson())))!;
      expect(back.primary!.protocol, 'vless-reality');
      expect(back.protocol, isNot(back.primary!.protocol));
      expect(back.hasSpare, isTrue);
      const alone = ColituSpareChoice(
        configId: 3,
        server: '',
        protocol: '',
        outbound: {},
        primary: ColituPath(server: 'de', protocol: 'trojan', outbound: {}),
      );
      expect(alone.hasSpare, isFalse);
    });
  });

  group('rule 9: core config details', () {
    Map<String, dynamic> config() {
      final s = XraySettingState();
      s.outbounds.outbounds.add(OutboundState());
      s.outbounds.outbounds.add(OutboundState()..tag = ColituWarmSpare.spareTag);
      return jsonDecode(jsonEncode(s.xrayJson.toJson())) as Map<String, dynamic>;
    }

    const v1 = ColituVerifyProxy(port: 1, user: 'a', pass: 'b');
    const v2 = ColituVerifyProxy(port: 2, user: 'c', pass: 'd');

    test('DNS module rule to the balancer right after the check rules', () {
      final c = config();
      expect(ColituWarmSpare.applyTo(c, verify: v1, verifySpare: v2), isTrue);
      final rules = ((c['routing'] as Map)['rules'] as List).cast<Map>();
      final dnsTag = (c['dns'] as Map)['tag'];
      expect((rules[2]['inboundTag'] as List), contains(dnsTag));
      expect(rules[2]['balancerTag'], 'proxy-auto');
      expect(colituConfigProblems(c), isEmpty);
    });

    test('TCP outbounds get tcpUserTimeout 10000 while a spare is attached', () {
      final c = config();
      ColituWarmSpare.applyTo(c, verify: v1, verifySpare: v2);
      for (final o in (c['outbounds'] as List).cast<Map>()) {
        if (o['tag'] != 'proxy' && o['tag'] != 'warm-spare') continue;
        final sockopt = (o['streamSettings'] as Map)['sockopt'] as Map;
        expect(sockopt['tcpUserTimeout'], 10000);
      }
    });
  });
}
