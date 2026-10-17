import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The transport that last worked may start first without a probe, but a
/// remembered TCP transport never keeps an unstalled Hysteria2 out
/// (Android ColituTransportOrder.remembered; iPhone report 10-17).
void main() {
  const all = ['hysteria2', 'vless-reality', 'vless-xhttp', 'trojan'];

  String? pick(String? lastGood, {Iterable<String> offered = all, Set<String> excluded = const {}}) =>
      ColituVPNConfigAdapter.rememberedTransport(lastGood: lastGood, offered: offered, excluded: excluded);

  test('no memory: the probe and the rank decide', () {
    expect(pick(null), isNull);
  });

  test('Hysteria2 that worked starts first', () {
    expect(pick('hysteria2'), 'hysteria2');
  });

  test('a remembered TCP transport does not keep an offered Hysteria2 out', () {
    expect(pick('vless-xhttp'), isNull);
    expect(pick('vless-reality'), isNull);
  });

  test('a remembered TCP transport starts first when Hysteria2 is stalled or hinted out', () {
    expect(pick('vless-xhttp', excluded: {'hysteria2'}), 'vless-xhttp');
  });

  test('a remembered TCP transport starts first when Hysteria2 is not offered', () {
    expect(pick('vless-reality', offered: ['vless-reality', 'vless-xhttp']), 'vless-reality');
  });

  test('a stalled remembered transport is never preferred', () {
    expect(pick('vless-xhttp', excluded: {'hysteria2', 'vless-xhttp'}), isNull);
    expect(pick('hysteria2', excluded: {'hysteria2'}), isNull);
  });
}
