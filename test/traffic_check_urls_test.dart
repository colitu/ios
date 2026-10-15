import 'package:colitu_vpn/core/network/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the server probe leads the traffic check when the node is named', () {
    expect(NetClient.trafficCheckUrlsFor('de1.example.test'), [
      'https://de1.example.test:3443/ping',
      ...NetClient.trafficCheckUrls,
    ]);
  });

  test('no server probe for an address, an empty or a missing host', () {
    for (final host in [null, '', '  ', '203.0.113.7', '2001:db8::1']) {
      expect(NetClient.trafficCheckUrlsFor(host), NetClient.trafficCheckUrls);
    }
  });

  test('no Cloudflare in the traffic check (throttled in Russia)', () {
    expect(
      NetClient.trafficCheckUrls.any((url) => url.contains('cloudflare')),
      isFalse,
    );
  });
}
