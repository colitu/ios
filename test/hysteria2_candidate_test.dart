import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/outbound/enum.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_reader.dart';
import 'package:colitu_vpn/service/xray/outbound/state_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The panel's Hysteria2 mobile profile must become a native Xray "hysteria"
/// outbound (Xray-core ≥ 1.260327 ships the QUIC transport), so iOS uses the
/// same fast transport as Windows without a second core.
void main() {
  final profile = {
    'format': 'xray-mobile-v1',
    'payload': {
      'schema_version': 1,
      'protocol': 'hysteria2',
      'endpoint': {'host': 'pro.example.test', 'port': 8443},
      'credentials': {'password': 'secret-pass'},
      'transport': {'type': 'hysteria'},
      'security': {'type': 'tls', 'server_name': 'pro.example.test'},
    },
  };

  test('hysteria2 profile becomes an Xray hysteria outbound', () {
    final candidate = VPNOutboundCandidate.fromProfile(profile);
    expect(candidate.protocolType, 'hysteria2');
    final outbound = XrayOutbound.fromJson(candidate.outboundConfig);
    final state = OutboundState();
    expect(state.readFromOutbound(outbound), isTrue);
    expect(state.protocol, XrayOutboundProtocol.hysteria);
    expect(state.network, StreamSettingsNetwork.hysteria);
    expect(state.security, StreamSettingsSecurity.tls);
    expect(state.address, 'pro.example.test');
    expect(state.port, '8443');
    expect(state.hysteriaAuth, 'secret-pass');
    expect(state.serverName, 'pro.example.test');
    expect(state.alpn, {StreamSettingsSecurityALPN.h3});

    final json = state.xrayJson.toJson();
    expect(json['protocol'], 'hysteria');
    expect(json['settings']['version'], 2);
    expect(json['settings']['address'], 'pro.example.test');
    expect(json['settings']['port'], 8443);
    expect(json['streamSettings']['network'], 'hysteria');
    expect(json['streamSettings']['hysteriaSettings']['version'], 2);
    expect(json['streamSettings']['hysteriaSettings']['auth'], 'secret-pass');
    expect(json['streamSettings']['tlsSettings']['alpn'], ['h3']);
  });

  test('transports are ranked Hysteria2 first', () {
    final rank = ColituVPNConfigAdapter.transportRank;
    expect(rank['hysteria2'], lessThan(rank['vless-reality']!));
    expect(rank['vless-reality'], lessThan(rank['trojan']!));
    expect(rank['trojan'], lessThan(rank['shadowsocks']!));
    // The screens show Colitu's names, never the protocol names.
    for (final protocol in ColituVPNConfigAdapter.transportRank.keys) {
      final name = colituTransportName(protocol);
      expect(name, isNotEmpty);
      expect(name, isNot(startsWith('transport.')));
      for (final technical in [
        'hysteria',
        'vless',
        'reality',
        'xhttp',
        'trojan',
        'shadowsocks',
      ]) {
        expect(name.toLowerCase(), isNot(contains(technical)));
      }
    }
    expect(colituTransportName(null), '');
  });
}
