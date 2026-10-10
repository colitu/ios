import 'dart:convert';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/warm_spare.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:colitu_vpn/service/xray/setting/state_writer.dart';
import 'package:flutter_test/flutter_test.dart';

VPNServer _server(String id, String country) => VPNServer.fromJson({
  'id': id,
  'name': id,
  'countryCode': country,
  'available': true,
});

/// A generated config shaped like the app's: primary first (default
/// outbound), system outbounds, rules on the primary, direct and block.
Map<String, dynamic> _config({bool spare = true}) =>
    jsonDecode(
          jsonEncode({
            'outbounds': [
              {'tag': 'proxy', 'protocol': 'hysteria'},
              if (spare) {'tag': 'warm-spare', 'protocol': 'vless'},
              {'tag': 'direct', 'protocol': 'freedom'},
              {'tag': 'fragment', 'protocol': 'freedom'},
              {'tag': 'block', 'protocol': 'blackhole'},
              {
                'tag': 'dnsOut',
                'protocol': 'dns',
                'streamSettings': {
                  'sockopt': {'dialerProxy': 'proxy'},
                },
              },
            ],
            'routing': {
              'domainStrategy': 'AsIs',
              'rules': [
                {'inboundTag': ['dns-module'], 'outboundTag': 'proxy'},
                {'port': '853', 'outboundTag': 'proxy'},
                {'domain': ['geosite:category-ads-all'], 'outboundTag': 'block'},
                {'ip': ['geoip:private'], 'outboundTag': 'direct'},
                {'domain': ['domain:example.org'], 'outboundTag': 'proxy'},
              ],
            },
          }),
        )
        as Map<String, dynamic>;

const _verify = ColituVerifyProxy(port: 40123, user: 'u1', pass: 'p1');
const _verifySpare = ColituVerifyProxy(port: 40124, user: 'u2', pass: 'p2');

void main() {
  group('spare transport', () {
    const all = ['hysteria2', 'vless-reality', 'vless-xhttp', 'trojan'];

    test('UDP primary gets a TCP spare, Reality first', () {
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'hysteria2',
          offered: all,
          sameServer: true,
        ),
        'vless-reality',
      );
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'hysteria2',
          offered: const ['hysteria2', 'trojan', 'vless-xhttp'],
          sameServer: true,
        ),
        'vless-xhttp',
      );
    });

    test('TCP primary gets Hysteria2 unless stalled, then another TCP', () {
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-reality',
          offered: all,
          sameServer: true,
        ),
        'hysteria2',
      );
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-reality',
          offered: all,
          stalled: const {'hysteria2'},
          sameServer: true,
        ),
        'vless-xhttp',
      );
    });

    test('same server with a single transport has no spare', () {
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-reality',
          offered: const ['vless-reality'],
          sameServer: true,
        ),
        isNull,
      );
      // Another server may run the primary's transport, as a last choice.
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-reality',
          offered: const ['vless-reality'],
          sameServer: false,
        ),
        'vless-reality',
      );
    });

    test('a rotating exit keeps the spare on VLESS', () {
      expect(
        ColituWarmSpare.pickTransport(
          primaryProtocol: 'vless-xhttp',
          offered: all,
          sameServer: true,
          vlessOnly: true,
        ),
        'vless-reality',
      );
    });

    test('setting off, multihop or unknown transport: no spare', () {
      bool wanted({bool enabled = true, bool multihop = false, String? p = 'trojan'}) =>
          ColituWarmSpare.wanted(
            enabled: enabled,
            multihop: multihop,
            primaryProtocol: p,
          );
      expect(wanted(), isTrue);
      expect(wanted(enabled: false), isFalse);
      expect(wanted(multihop: true), isFalse);
      expect(wanted(p: null), isFalse);
    });
  });

  group('spare server', () {
    final now = DateTime(2026, 10, 9, 12);
    const net = 'wifi|TR-AS1';
    final de = _server('de', 'DE');
    final nl = _server('nl', 'NL');
    final fi = _server('fi', 'FI');

    test('next ranked server that is not penalized', () {
      final memory = ColituAdaptiveMemory()..penalize(net, 'nl', now);
      expect(
        ColituWarmSpare.pickServer(
          [de, nl, fi],
          de,
          memory: memory,
          network: net,
          now: now,
        )?.id,
        'fi',
      );
    });

    test('multihop routes and the primary itself are never the spare', () {
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
      expect(
        ColituWarmSpare.pickServer(
          [route, de],
          de,
          memory: ColituAdaptiveMemory(),
          network: net,
          now: now,
        ),
        isNull,
      );
    });
  });

  group('core config', () {
    test('random check credentials differ per start', () {
      final a = ColituVerifyProxy.random(1);
      final b = ColituVerifyProxy.random(1);
      expect(a.user.length, 32);
      expect(a.pass, isNot(b.pass));
    });

    test('balancer, observatory and every former proxy rule on it', () {
      final config = _config();
      expect(ColituWarmSpare.applyTo(config, verify: _verify, verifySpare: _verifySpare), isTrue);

      final routing = config['routing'] as Map<String, dynamic>;
      final rules = (routing['rules'] as List).cast<Map<String, dynamic>>();
      // Only the check inbound's rule still names the primary directly.
      expect(rules.where((r) => r['outboundTag'] == 'proxy'), [rules.first]);
      expect(
        rules.where((r) => r['balancerTag'] == 'proxy-auto').length,
        4,
        reason: 'three former proxy rules and the catch-all',
      );
      expect(rules.last, {'network': 'tcp,udp', 'balancerTag': 'proxy-auto'});
      expect(rules[4]['outboundTag'], 'block');
      expect(rules[5]['outboundTag'], 'direct');
      // The spare's own check rule is second and goes to the spare only.
      expect(rules[1], {
        'inboundTag': ['colitu-verify-spare'],
        'outboundTag': 'warm-spare',
      });

      final balancer = (routing['balancers'] as List).single as Map;
      expect(balancer['tag'], 'proxy-auto');
      expect(balancer['selector'], ['proxy']);
      expect(balancer['fallbackTag'], 'warm-spare');
      // Xray selectors match by prefix: the spare's tag must not start
      // with the primary's.
      expect('warm-spare'.startsWith('proxy'), isFalse);

      // The connect-time check inbound: first rule, straight to the
      // primary, never the balancer; loopback only, with credentials.
      expect(rules.first, {
        'inboundTag': ['colitu-verify'],
        'outboundTag': 'proxy',
      });
      expect(
        rules.skip(1).where(
          (r) => (r['inboundTag'] as List?)?.contains('colitu-verify') == true,
        ),
        isEmpty,
      );
      expect((config['inbounds'] as List).length, 2);
      final inbound = (config['inbounds'] as List).first as Map;
      expect(inbound['tag'], 'colitu-verify');
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['port'], 40123);
      expect(inbound['protocol'], 'http');
      expect(inbound['settings'], {
        'accounts': [
          {'user': 'u1', 'pass': 'p1'},
        ],
      });
      expect(_verify.directive, 'PROXY u1:p1@127.0.0.1:40123');

      final observatory = config['burstObservatory'] as Map<String, dynamic>;
      expect(observatory['subjectSelector'], ['proxy']);
      final ping = observatory['pingConfig'] as Map<String, dynamic>;
      expect(ping['destination'], 'http://www.gstatic.com/generate_204');
      expect(
        ping['connectivity'],
        'http://connectivitycheck.gstatic.com/generate_204',
      );
      expect(ping['interval'], '10s');
      expect(ping['sampling'], 1);
      expect(ping['timeout'], '3s');
    });

    test('without a spare outbound the config stays as it is', () {
      final config = _config(spare: false);
      final before = jsonEncode(config);
      expect(ColituWarmSpare.applyTo(config, verify: _verify, verifySpare: _verifySpare), isFalse);
      expect(jsonEncode(config), before);
      expect(config.containsKey('burstObservatory'), isFalse);
    });

    test('a stored choice round-trips', () {
      const choice = ColituSpareChoice(
        configId: 7,
        server: 'fi',
        protocol: 'vless-reality',
        outbound: {'protocol': 'vless'},
      );
      final back = ColituSpareChoice.fromJson(
        jsonDecode(jsonEncode(choice.toJson())),
      )!;
      expect(back.configId, 7);
      expect(back.protocol, 'vless-reality');
      expect(back.outbound, {'protocol': 'vless'});
      expect(ColituSpareChoice.fromJson('x'), isNull);
    });
  });

  group('tag integrity of the generated config', () {
    // Built like the tunnel start does it: a fresh setting state per start,
    // the primary (and the spare) as outbounds, the warm-spare rewrite on a
    // copy of the finished JSON.
    XraySettingState state({required bool spare}) {
      final s = XraySettingState();
      s.outbounds.outbounds.add(OutboundState());
      if (spare) {
        s.outbounds.outbounds.add(
          OutboundState()..tag = ColituWarmSpare.spareTag,
        );
      }
      // As _hardenDnsLeakProtection: the DNS outbound dials via the primary.
      s.outbounds.dns.dialerProxy = 'proxy';
      return s;
    }

    Map<String, dynamic> json(XraySettingState s) =>
        jsonDecode(jsonEncode(s.xrayJson.toJson())) as Map<String, dynamic>;

    List<String> targets(Map<String, dynamic> config) => [
      for (final r in (config['routing'] as Map)['rules'] as List)
        '${(r as Map)['outboundTag'] ?? (r)['balancerTag']}',
    ];

    test('spare off: every rule target exists', () {
      final off = json(state(spare: false));
      expect(colituConfigProblems(off), isEmpty);
      expect(targets(off), contains('proxy'));
      expect(jsonEncode(off), isNot(contains('proxy-auto')));
    });

    test('spare on: balancer, check inbound and DNS module all resolve', () {
      final on = json(state(spare: true));
      expect(ColituWarmSpare.applyTo(on, verify: _verify, verifySpare: _verifySpare), isTrue);
      expect(colituConfigProblems(on), isEmpty);
      // DNS module queries (inbound dnsQuery) reach the balancer, which
      // always has an outbound (primary or spare).
      final rules = ((on['routing'] as Map)['rules'] as List).cast<Map>();
      final dns = rules.firstWhere(
        (r) => (r['inboundTag'] as List?)?.contains('dnsQuery') == true,
      );
      expect(dns['balancerTag'], 'proxy-auto');
      expect(dns.containsKey('outboundTag'), isFalse);
      // Only the check rule names the primary directly.
      expect(
        rules.where((r) => r['outboundTag'] == 'proxy'),
        [rules.first],
      );
    });

    test('spare off after on: nothing left over from the spare', () {
      final before = jsonEncode(json(state(spare: false)));
      final withSpare = state(spare: true);
      final on = json(withSpare);
      ColituWarmSpare.applyTo(on, verify: _verify, verifySpare: _verifySpare);
      // The rewrite worked on a copy: the setting state is untouched...
      expect(jsonEncode(json(withSpare)), isNot(contains('proxy-auto')));
      // ...and the next start without a spare is today's config exactly.
      final after = json(state(spare: false));
      expect(jsonEncode(after), before);
      expect(colituConfigProblems(after), isEmpty);
    });

    test('the checker finds dangling targets and a loose check rule', () {
      final broken = json(state(spare: false));
      final rules = (broken['routing'] as Map)['rules'] as List;
      rules.add({'balancerTag': 'proxy-auto'});
      rules.add({'inboundTag': ['colitu-verify', 'tun-in'], 'outboundTag': 'proxy'});
      final problems = colituConfigProblems(broken);
      expect(problems.any((p) => p.contains('missing balancer')), isTrue);
      expect(problems.any((p) => p.contains('check inbound rule')), isTrue);
    });
  });
}
