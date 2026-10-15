import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_reader.dart';
import 'package:colitu_vpn/service/xray/outbound/state_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Port hopping for Hysteria2: the panel's transport may carry hop_ports and
/// hop_interval, which become Xray 26.9+'s "udphop" UDP mask in finalmask.udp.
void main() {
  Map<String, dynamic> profile(Map<String, dynamic> transport) => {
    'format': 'xray-mobile-v1',
    'payload': {
      'schema_version': 1,
      'protocol': 'hysteria2',
      'endpoint': {'host': 'pro.example.test', 'port': 8443},
      'credentials': {'password': 'secret-pass'},
      'transport': {'type': 'hysteria', ...transport},
      'security': {'type': 'tls', 'server_name': 'pro.example.test'},
    },
  };

  Map<String, dynamic> written(Map<String, dynamic> transport) {
    final candidate = VPNOutboundCandidate.fromProfile(profile(transport));
    final state = OutboundState();
    expect(
      state.readFromOutbound(XrayOutbound.fromJson(candidate.outboundConfig)),
      isTrue,
    );
    return state.xrayJson.toJson();
  }

  Map<String, dynamic> hop(int interval) => {
    'udp': [
      {
        'type': 'udphop',
        'settings': {
          'mode': 'intervalLocal,intervalRemote',
          'interval': interval,
          'remotePorts': '20000-40000',
        },
      },
    ],
  };

  test('hop_ports becomes the udphop UDP mask', () {
    final candidate = VPNOutboundCandidate.fromProfile(
      profile({'hop_ports': '20000-40000', 'hop_interval': 30}),
    );
    expect(candidate.outboundConfig['streamSettings']['finalmask'], hop(30));

    // It survives the outbound state round trip into the written config.
    final json = written({'hop_ports': '20000-40000', 'hop_interval': 15});
    final stream = json['streamSettings'] as Map<String, dynamic>;
    expect(stream['finalmask'], hop(15));
    // The older shapes, which Xray 26.10 ignores, are not used.
    expect(stream['finalmask'], isNot(contains('quicParams')));
    // The old shape, which Xray 26 ignores, is not used.
    expect(stream['hysteriaSettings'], isNot(contains('udphop')));
  });

  test('without a valid hop range the config is unchanged', () {
    final plain = written({});
    expect(plain['streamSettings'], isNot(contains('finalmask')));
    for (final invalid in [
      '',
      '20000',
      '20000-40000,50000',
      '200-400',
      '40000-20000',
      '20000-70000',
      ' 20000-x ',
    ]) {
      expect(
        written({'hop_ports': invalid, 'hop_interval': 30}),
        plain,
        reason: invalid,
      );
    }
  });

  test('a missing interval falls back to 30 seconds', () {
    final candidate = VPNOutboundCandidate.fromProfile(
      profile({'hop_ports': '20000-40000'}),
    );
    expect(candidate.outboundConfig['streamSettings']['finalmask'], hop(30));
  });

  test('an interval under 5 s (refused by the core) becomes 5 s', () {
    final candidate = VPNOutboundCandidate.fromProfile(
      profile({'hop_ports': '20000-40000', 'hop_interval': 2}),
    );
    expect(candidate.outboundConfig['streamSettings']['finalmask'], hop(5));
  });
}
