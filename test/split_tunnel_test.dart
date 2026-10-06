import 'dart:convert';

import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/service/tun_setting/state.dart';
import 'package:colitu_vpn/service/xray/raw/fix.dart';
import 'package:flutter_test/flutter_test.dart';

/// A configuration as the app reads it: decoded JSON, dynamic types.
Map<String, dynamic> _config() =>
    jsonDecode(jsonEncode(_configLiteral)) as Map<String, dynamic>;

const _configLiteral = {
  'inbounds': [
    {
      'tag': 'tunIn',
      'protocol': 'tun',
      'sniffing': {
        'enabled': true,
        'destOverride': ['tls'],
      },
    },
  ],
  'outbounds': [
    {'tag': 'proxy', 'protocol': 'vless'},
    {'tag': 'direct', 'protocol': 'freedom'},
  ],
  'dns': {
    'servers': [
      '1.1.1.1',
      {'address': '8.8.8.8', 'queryStrategy': 'UseIP'},
    ],
  },
  'routing': {
    'rules': [
      {'inboundTag': ['dnsQuery'], 'outboundTag': 'proxy'},
      {'outboundTag': 'dnsOut', 'port': '53'},
      {'ip': ['geoip:private'], 'outboundTag': 'direct'},
    ],
  },
};

List<Map<String, dynamic>> _rules(Map<String, dynamic> config) =>
    ((config['routing'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

void main() {
  tearDown(() {
    ColituSplitTunnel.current = SplitTunnelSettings.off;
    ColituRuBypass.privacyMode = false;
    ColituRuBypass.serverCountry = null;
  });

  group('validation', () {
    test('domains are normalised', () {
      expect(ColituSplitTunnel.normalizeDomain('Example.COM'), 'example.com');
      expect(ColituSplitTunnel.normalizeDomain('https://www.example.com/a?b'), 'www.example.com');
      expect(ColituSplitTunnel.normalizeDomain('*.example.com'), 'example.com');
      expect(ColituSplitTunnel.normalizeDomain('.example.com.'), 'example.com');
      expect(ColituSplitTunnel.normalizeDomain('example.com:8443'), 'example.com');
      expect(ColituSplitTunnel.normalizeDomain('президент.рф'), 'xn--d1abbgf6aiiy.xn--p1ai');
      expect(ColituSplitTunnel.normalizeDomain('bücher.de'), 'xn--bcher-kva.de');
    });

    test('non-domains are refused', () {
      for (final bad in ['', 'localhost', 'exa mple.com', '-bad.com', 'a..b', '1.2.3.4', 'user@example.com', 'ex_ample.com', 'a.b:xyz']) {
        expect(ColituSplitTunnel.normalizeDomain(bad), isNull, reason: bad);
      }
    });

    test('networks are masked to their prefix', () {
      expect(ColituSplitTunnel.normalizeNetwork('203.0.113.7/24'), '203.0.113.0/24');
      expect(ColituSplitTunnel.normalizeNetwork('198.51.100.9'), '198.51.100.9/32');
      expect(ColituSplitTunnel.normalizeNetwork('2001:DB8::1/32'), '2001:db8::/32');
      expect(ColituSplitTunnel.normalizeNetwork('2001:db8::5'), '2001:db8::5/128');
    });

    test('too wide, special or malformed networks are refused', () {
      for (final bad in ['10.0.0.0/7', '0.0.0.0/0', '127.0.0.1', '224.0.0.1', '256.1.1.1', '1.2.3', '1.2.3.4/33', '1.2.3.4/x', '::/0', '::1', 'ff02::1', '2001:db8::/8', 'example.com']) {
        expect(ColituSplitTunnel.normalizeNetwork(bad), isNull, reason: bad);
      }
    });

    test('add refuses invalid, duplicate and too many entries', () {
      var settings = const SplitTunnelSettings(mode: SplitTunnelMode.bypass);
      expect(settings.add('not a site').error, SplitTunnelEntryError.invalid);
      settings = settings.add('example.com').settings!;
      expect(settings.add('EXAMPLE.com').error, SplitTunnelEntryError.duplicate);
      settings = settings.add('203.0.113.9/24').settings!;
      expect(settings.domains, ['example.com']);
      expect(settings.ips, ['203.0.113.0/24']);
      var full = const SplitTunnelSettings();
      for (var i = 0; i < ColituSplitTunnel.maxEntries; i++) {
        full = full.add('site$i.example').settings!;
      }
      expect(full.add('one-more.example').error, SplitTunnelEntryError.tooMany);
    });

    test('stored settings round-trip and drop entries that no longer validate', () {
      const settings = SplitTunnelSettings(
        mode: SplitTunnelMode.only,
        domains: ['example.com'],
        ips: ['203.0.113.0/24'],
      );
      expect(SplitTunnelSettings.decode(settings.encode()), settings);
      final dirty = SplitTunnelSettings.fromJson({
        'mode': 'bypass',
        'domains': ['ok.example', 'bad domain', 7],
        'ips': ['0.0.0.0/0', '198.51.100.1'],
      });
      expect(dirty.domains, ['ok.example']);
      expect(dirty.ips, ['198.51.100.1/32']);
      expect(SplitTunnelSettings.decode('{broken'), SplitTunnelSettings.off);
      expect(SplitTunnelSettings.fromJson({'mode': 'weird'}).mode, SplitTunnelMode.off);
    });
  });

  group('xray configuration', () {
    test('off or an empty list changes nothing', () {
      final config = _config();
      ColituSplitTunnel.applyTo(config, SplitTunnelSettings.off);
      ColituSplitTunnel.applyTo(config, const SplitTunnelSettings(mode: SplitTunnelMode.bypass));
      expect(config, _config());
    });

    test('bypass sends the list direct, after the DNS rules', () {
      final config = _config();
      ColituSplitTunnel.applyTo(
        config,
        const SplitTunnelSettings(
          mode: SplitTunnelMode.bypass,
          domains: ['example.com'],
          ips: ['203.0.113.0/24'],
        ),
      );
      final rules = _rules(config);
      expect(rules[0]['inboundTag'], ['dnsQuery']);
      expect(rules[1]['outboundTag'], 'dnsOut');
      expect(rules[2], {
        'inboundTag': ['tunIn'],
        'domain': ['domain:example.com'],
        'outboundTag': 'direct',
        'ruleTag': ColituSplitTunnel.ruleTag,
      });
      expect(rules[3]['ip'], ['203.0.113.0/24']);
      expect(rules[3]['outboundTag'], 'direct');
      expect(rules.length, 5);
      // Domain rules need the sniffed name: http is added, tls kept.
      final sniffing = (config['inbounds'] as List).first['sniffing'] as Map;
      expect(sniffing['destOverride'], ['tls', 'http']);
    });

    test('only sends the list to the proxy and everything else direct', () {
      final config = _config();
      ColituSplitTunnel.applyTo(
        config,
        const SplitTunnelSettings(mode: SplitTunnelMode.only, domains: ['example.com']),
      );
      final rules = _rules(config).where((r) => r['ruleTag'] == ColituSplitTunnel.ruleTag).toList();
      expect(rules, hasLength(2));
      expect(rules[0]['outboundTag'], 'proxy');
      expect(rules[1], {
        'inboundTag': ['tunIn'],
        'network': 'tcp,udp',
        'outboundTag': 'direct',
        'ruleTag': ColituSplitTunnel.ruleTag,
      });
    });

    test('rewriting replaces the previous rules', () {
      final config = _config();
      const settings = SplitTunnelSettings(mode: SplitTunnelMode.bypass, domains: ['a.example']);
      ColituSplitTunnel.applyTo(config, settings);
      ColituSplitTunnel.applyTo(config, settings);
      expect(_rules(config).where((r) => r['ruleTag'] == ColituSplitTunnel.ruleTag), hasLength(1));
      ColituSplitTunnel.applyTo(config, SplitTunnelSettings.off);
      expect(_rules(config).where((r) => r['ruleTag'] == ColituSplitTunnel.ruleTag), isEmpty);
    });

    test('sniffing is switched on (route only) when the inbound had none', () {
      final config = _config();
      (config['inbounds'] as List).first.remove('sniffing');
      ColituSplitTunnel.applyTo(
        config,
        const SplitTunnelSettings(mode: SplitTunnelMode.bypass, domains: ['example.com']),
      );
      expect((config['inbounds'] as List).first['sniffing'], {
        'enabled': true,
        'destOverride': ['http', 'tls'],
        'routeOnly': true,
      });
    });

    test('privacy mode does not filter the user list; the Russian rule stays separate', () async {
      ColituRuBypass.privacyMode = true;
      ColituSplitTunnel.current = const SplitTunnelSettings(
        mode: SplitTunnelMode.bypass,
        domains: ['yandex.ru'],
      );
      final config = _config();
      final tun = TunSettingState();
      XrayRawFix.fixRussianIpBypass(config);
      ColituSplitTunnel.applyTo(config, ColituSplitTunnel.current);
      final rules = _rules(config);
      expect(rules.any((r) => r['ruleTag'] == 'ruBypass'), isFalse);
      expect(rules.any((r) => (r['domain'] as List?)?.contains('domain:yandex.ru') ?? false), isTrue);
      expect(tun.enableIPv6, isFalse);
    });
  });

  group('tunnel routes', () {
    test('only bypass IP ranges are excluded, never the tunnel DNS', () {
      const settings = SplitTunnelSettings(
        mode: SplitTunnelMode.bypass,
        domains: ['example.com'],
        ips: ['203.0.113.0/24', '8.8.8.0/24', '2001:db8::/32'],
      );
      expect(
        ColituSplitTunnel.excludedRoutes(settings, keepInside: ['8.8.8.8', '2001:4860:4860::8888']),
        ['203.0.113.0/24', '2001:db8::/32'],
      );
      expect(
        ColituSplitTunnel.excludedRoutes(settings.copyWith(mode: SplitTunnelMode.only)),
        isEmpty,
      );
    });

    test('the start request carries the strict kill switch and routes', () {
      final tun = TunSettingState()
        ..includeAllNetworks = true
        ..excludedRoutes = ['203.0.113.0/24'];
      final json = tun.tunJson.toJson();
      expect(json['includeAllNetworks'], true);
      expect(json['excludedRoutes'], ['203.0.113.0/24']);
      final plain = TunSettingState().tunJson.toJson();
      expect(plain.containsKey('includeAllNetworks'), isFalse);
      expect(plain.containsKey('excludedRoutes'), isFalse);
    });
  });

  test('IPv6 off: the core resolves IPv4 only', () {
    final config = _config();
    XrayRawFix.fixIPv4OnlyDns(config);
    final dns = config['dns'] as Map;
    expect(dns['queryStrategy'], 'UseIPv4');
    expect((dns['servers'] as List)[1]['queryStrategy'], 'UseIPv4');
    expect((dns['servers'] as List)[0], '1.1.1.1');
    final noDns = <String, dynamic>{};
    XrayRawFix.fixIPv4OnlyDns(noDns);
    expect(noDns, isEmpty);
  });
}
