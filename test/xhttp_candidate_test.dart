import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/outbound/enum.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_reader.dart';
import 'package:colitu_vpn/service/xray/outbound/state_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The panel's VLESS XHTTP profile (Reality security, XHTTP transport) must
/// survive the round trip through the outbound editor state unchanged.
void main() {
  Map<String, dynamic> profile({Map<String, dynamic>? transport}) => {
    'format': 'xray-mobile-v1',
    'payload': {
      'schema_version': 1,
      'protocol': 'vless-xhttp',
      'endpoint': {'host': 'tr.example.test', 'port': 2053},
      'credentials': {'uuid': '00000000-0000-4000-8000-000000000003'},
      'transport':
          transport ??
          {'type': 'xhttp', 'path': '/fixture-path', 'mode': 'auto'},
      'security': {
        'type': 'reality',
        'server_name': 'www.cloudflare.com',
        'public_key': 'fixture-public-key',
        'short_id': 'abcd',
        'fingerprint': 'chrome',
      },
    },
  };

  test('vless-xhttp profile becomes a VLESS XHTTP Reality outbound', () {
    final candidate = VPNOutboundCandidate.fromProfile(profile());
    expect(candidate.protocolType, 'vless-xhttp');
    final state = OutboundState();
    expect(
      state.readFromOutbound(XrayOutbound.fromJson(candidate.outboundConfig)),
      isTrue,
    );
    expect(state.protocol, XrayOutboundProtocol.vless);
    expect(state.network, StreamSettingsNetwork.xhttp);
    expect(state.security, StreamSettingsSecurity.reality);

    final json = state.xrayJson.toJson();
    final stream = json['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'xhttp');
    expect(stream['xhttpSettings']['path'], '/fixture-path');
    expect(stream['xhttpSettings']['mode'], 'auto');
    expect(stream['security'], 'reality');
    expect(stream['realitySettings']['serverName'], 'www.cloudflare.com');
    // Current Xray names the Reality public key "password".
    expect(stream['realitySettings']['password'], 'fixture-public-key');
    expect(stream['realitySettings']['shortId'], 'abcd');
    final settings = json['settings'] as Map<String, dynamic>;
    expect(settings['address'], 'tr.example.test');
    expect(settings['port'], 2053);
    expect(settings['id'], '00000000-0000-4000-8000-000000000003');
    expect(settings['flow'] ?? '', isEmpty);
  });

  test('a vless-xhttp profile without a path is rejected', () {
    expect(
      () => VPNOutboundCandidate.fromProfile(
        profile(transport: {'type': 'xhttp', 'mode': 'auto'}),
      ),
      throwsFormatException,
    );
    expect(
      () => VPNOutboundCandidate.fromProfile(
        profile(transport: {'type': 'tcp', 'path': '/p'}),
      ),
      throwsFormatException,
    );
  });

  test('XHTTP ranks after VLESS Reality and before Trojan', () {
    final rank = ColituVPNConfigAdapter.transportRank;
    expect(rank['vless-reality'], lessThan(rank['vless-xhttp']!));
    expect(rank['vless-xhttp'], lessThan(rank['trojan']!));
    expect(colituTransportName('vless-xhttp'), isNot(contains('XHTTP')));
  });
}
