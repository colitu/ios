import 'dart:convert';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/core_config_finish.dart';
import 'package:colitu_vpn/colitu/services/tunnel_inbounds.dart';
import 'package:colitu_vpn/colitu/services/warm_spare.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:colitu_vpn/service/xray/setting/state_writer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core configurations as the VPN service writes them (vpn/service.dart
/// _writeXrayUIConfig), checked for what Xray 26.10 refuses: duplicate rule
/// tags, `allowInsecure`, certificate pins without a server name, the old
/// XHTTP session field names and the old port-hopping shapes.
///
/// With COLITU_DUMP_CONFIGS set to a directory, the configurations are also written there,
/// for a load test with the real core (see the 2026-10-13 update report).
void main() {
  const realityKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  Map<String, dynamic> payload(
    String protocol,
    Map<String, dynamic> transport,
    Map<String, dynamic> security,
    Map<String, dynamic> credentials,
  ) => {
    'format': 'xray-mobile-v1',
    'payload': {
      'schema_version': 1,
      'protocol': protocol,
      'endpoint': {'host': 'node.example.test', 'port': 8443},
      'credentials': credentials,
      'transport': transport,
      'security': security,
    },
  };

  final reality = {
    'type': 'reality',
    'server_name': 'www.example.com',
    'public_key': realityKey,
    'short_id': 'abcd',
    'fingerprint': 'chrome',
  };
  const uuid = {'uuid': '00000000-0000-4000-8000-000000000003'};
  final profiles = <String, Map<String, dynamic>>{
    'vless-reality': payload('vless-reality', {'type': 'tcp'}, reality, uuid),
    'vless-xhttp': payload(
      'vless-xhttp',
      {'type': 'xhttp', 'path': '/p', 'mode': 'auto'},
      reality,
      uuid,
    ),
    'trojan': payload(
      'trojan',
      {'type': 'tcp'},
      {'type': 'tls', 'server_name': 'node.example.test'},
      {'password': 'secret-pass'},
    ),
    'hysteria2': payload(
      'hysteria2',
      {'type': 'hysteria', 'hop_ports': '20000-40000', 'hop_interval': 30},
      {'type': 'tls', 'server_name': 'node.example.test'},
      {'password': 'secret-pass'},
    ),
  };

  Map<String, dynamic> build(
    String name, {
    SplitTunnelSettings split = SplitTunnelSettings.off,
    bool spare = false,
    bool adBlock = false,
  }) {
    final adapter = ColituVPNConfigAdapter();
    final candidate = VPNOutboundCandidate.fromProfile(profiles[name]!);
    final settingState = XraySettingState();
    settingState.outbounds.outbounds.add(
      adapter.outboundStateFor(candidate.outboundConfig, name)
        ..tag = ColituWarmSpare.primaryTag,
    );
    if (spare) {
      final other = VPNOutboundCandidate.fromProfile(profiles['trojan']!);
      settingState.outbounds.outbounds.add(
        adapter.outboundStateFor(other.outboundConfig, 'spare')
          ..tag = ColituWarmSpare.spareTag,
      );
    }
    if (adBlock) {
      ColituAdBlock.applyTo(
        settingState,
        servers: const ['https://dns.example.test/dns-query'],
      );
    }
    final xrayJson = settingState.xrayJson;
    ColituTunnelInbounds.stripPing(xrayJson);
    final json =
        jsonDecode(jsonEncode(xrayJson.toJson())) as Map<String, dynamic>;
    ColituSplitTunnel.applyTo(json, split);
    if (spare) {
      expect(
        ColituWarmSpare.applyTo(
          json,
          verify: ColituVerifyProxy.random(41001),
          verifySpare: ColituVerifyProxy.random(41002),
        ),
        isTrue,
      );
    }
    ColituCoreConfig.uniqueRuleTags(json);
    return json;
  }

  void expectAccepted(Map<String, dynamic> json, {String? reason}) {
    final rules = (json['routing'] as Map)['rules'] as List;
    final tags = [
      for (final rule in rules)
        if (rule is Map && rule['ruleTag'] is String) rule['ruleTag'],
    ];
    expect(
      tags.toSet().length,
      tags.length,
      reason: 'duplicate ruleTag $reason',
    );
    final text = jsonEncode(json);
    expect(text, isNot(contains('allowInsecure')), reason: reason);
    expect(text, isNot(contains('sessionPlacement')), reason: reason);
    expect(text, isNot(contains('"sessionKey"')), reason: reason);
    expect(text, isNot(contains('udpHop')), reason: reason);
    expect(text, isNot(contains('"udphop":')), reason: reason);
    for (final outbound in json['outbounds'] as List) {
      final tls = ((outbound as Map)['streamSettings'] as Map?)?['tlsSettings'];
      if (tls is Map && tls['pinnedPeerCertSha256'] != null) {
        expect('${tls['serverName'] ?? ''}', isNotEmpty, reason: reason);
      }
    }
  }

  setUp(() {
    ColituRuBypass.privacyMode = false;
    ColituRuBypass.serverCountry = 'FI';
  });

  test('every transport, with split tunneling, spare and ad blocking', () {
    final dump = Platform.environment['COLITU_DUMP_CONFIGS'];
    const bypass = SplitTunnelSettings(
      mode: SplitTunnelMode.bypass,
      domains: ['example.com', 'example.org'],
      ips: ['198.51.100.0/24'],
    );
    const only = SplitTunnelSettings(
      mode: SplitTunnelMode.only,
      domains: ['example.com'],
      ips: ['198.51.100.0/24'],
    );
    for (final name in profiles.keys) {
      final variants = {
        '$name-plain': build(name),
        '$name-bypass-spare-adblock': build(
          name,
          split: bypass,
          spare: true,
          adBlock: true,
        ),
        '$name-only': build(name, split: only),
      };
      for (final entry in variants.entries) {
        expectAccepted(entry.value, reason: entry.key);
        if (dump != null && dump.isNotEmpty) {
          File('$dump/${entry.key}.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(entry.value),
          );
        }
      }
    }
    if (dump != null) debugPrint('configs written to $dump');
  });

  test('split tunneling reaches the written configuration', () {
    final json = build(
      'vless-reality',
      split: const SplitTunnelSettings(
        mode: SplitTunnelMode.bypass,
        domains: ['example.com'],
        ips: ['198.51.100.0/24'],
      ),
    );
    final rules = (json['routing'] as Map)['rules'] as List;
    final split = rules
        .whereType<Map>()
        .where((r) => '${r['ruleTag']}'.startsWith(ColituSplitTunnel.ruleTag))
        .toList();
    expect(split, hasLength(2));
    expect(split.map((r) => r['ruleTag']), [
      ColituSplitTunnel.ruleTag,
      '${ColituSplitTunnel.ruleTag}#2',
    ]);
    expect(split.first['domain'], ['domain:example.com']);
    expect(split.first['outboundTag'], 'direct');
  });

  test('unique rule tags: later duplicates get a number', () {
    final config = <String, dynamic>{
      'routing': {
        'rules': [
          {'ruleTag': 'a'},
          {'ruleTag': 'a'},
          {'ruleTag': 'a#2'},
          {'ruleTag': 'a'},
          {'outboundTag': 'proxy'},
          {'ruleTag': 'b'},
        ],
      },
    };
    ColituCoreConfig.uniqueRuleTags(config);
    final tags = [
      for (final r in (config['routing'] as Map)['rules'] as List) r['ruleTag'],
    ];
    expect(tags, ['a', 'a#3', 'a#2', 'a#4', null, 'b']);
  });
}
