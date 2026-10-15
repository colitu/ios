import 'package:flutter_test/flutter_test.dart';
import 'package:colitu_vpn/colitu/services/site_redaction.dart';

void main() {
  const known = ['node1.example-vpn.net', '203.0.113.7'];
  String mask(String text) => SiteRedaction.mask(text, knownHosts: known);

  test('dial targets of visited sites are masked', () {
    expect(mask('proxy: dial tcp:www.whatsapp.com:443 failed'), 'proxy: dial tcp:<site>:443 failed');
    expect(mask('udp:[2a03:2880::1]:443'), 'udp:<ip>:443');
    expect(mask('tcp:157.240.1.35:443'), 'tcp:<ip>:443');
  });

  test('lookups are masked, files are not', () {
    expect(mask('dns: lookup instagram.com on 1.1.1.1'), 'dns: lookup <site> on 1.1.1.1');
    expect(mask('sniffed domain: i.instagram.com.'), 'sniffed domain: <site>');
    expect(mask('response for www.whatsapp.com. A'), 'response for <site> A');
    expect(mask('resolving drops.jsonl failed'), 'resolving drops.jsonl failed');
    expect(mask('query for stability_log.jsonl'), 'query for stability_log.jsonl');
  });

  test('URL hosts are masked', () {
    expect(mask('GET https://www.instagram.com/x?y=1'), 'GET https://<site>/x?y=1');
    expect(mask('wss://1.2.3.4/ws'), 'wss://<ip>/ws');
  });

  test('Colitu servers, their domain and check hosts stay readable', () {
    const lines = [
      'dial tcp:node1.example-vpn.net:443',
      'dial udp:other.example-vpn.net:8443',
      'lookup node1.example-vpn.net',
      'tcp:203.0.113.7:443',
      'https://api.colitu.com/v1',
      'https://colitu.com/',
      'tcp:127.0.0.1:1080',
      'tcp:[::1]:1080',
      'GET http://connectivitycheck.gstatic.com/generate_204',
      'tcp:www.gstatic.com:443',
      'ping 8.8.8.8 and lookup ya.ru',
    ];
    for (final line in lines) {
      expect(mask(line), line);
    }
  });

  test('a lookalike of a known host is not kept', () {
    expect(mask('lookup node1.example-vpn.net.evil.org'), 'lookup <site>');
  });

  test('Go network errors are masked', () {
    expect(
      mask('failed to open connection to tcp:<site>:443 > dial tcp 95.100.1.2:443: i/o timeout'),
      'failed to open connection to tcp:<site>:443 > dial tcp <ip>:443: i/o timeout',
    );
    expect(
      mask('read tcp 192.168.20.2:51000->157.240.1.35:443: read: connection reset by peer'),
      'read tcp <ip>:51000-><ip>:443: read: connection reset by peer',
    );
    expect(mask('write udp6 [fc00::1]:5353->[2a03:2880::1]:443: broken pipe'), 'write udp6 [<ip>]:5353-><ip>:443: broken pipe');
    expect(mask('dial tcp4 www.whatsapp.com:443: refused'), 'dial tcp4 <site>:443: refused');
    expect(mask('dial tcp 203.0.113.7:443: i/o timeout'), 'dial tcp 203.0.113.7:443: i/o timeout');
  });

  test('sing-box, DNS answers, JSON addresses and SNI are masked', () {
    expect(mask('outbound/vless[proxy]: outbound connection to www.instagram.com:443'),
        'outbound/vless[proxy]: outbound connection to <site>:443');
    expect(mask('inbound/tun[tun-in]: inbound connection to 31.13.72.36:443'),
        'inbound/tun[tun-in]: inbound connection to <ip>:443');
    expect(mask('app/dns: UDP:8.8.8.8:53 got answer: www.instagram.com. TypeA -> [31.13.72.36]'),
        'app/dns: UDP:8.8.8.8:53 got answer: <site> TypeA -> [<ip>]');
    expect(mask('dns: exchanged i.instagram.com A'), 'dns: exchanged <site> A');
    expect(mask('{"addr":"www.whatsapp.com:443","n":1}'), '{"addr":"<site>:443","n":1}');
    expect(mask('{"addr":"node1.example-vpn.net:443"}'), '{"addr":"node1.example-vpn.net:443"}');
    expect(mask('tls handshake failed sni=www.instagram.com'), 'tls handshake failed sni=<site>');
  });

  test('stray addresses are masked; times, versions and known hosts are not', () {
    expect(mask('peer 31.13.72.36 closed'), 'peer <ip> closed');
    expect(mask('peer 2a03:2880:f10c::1 closed'), 'peer <ip> closed');
    expect(mask('server 203.0.113.7 and resolver 8.8.8.8'), 'server 203.0.113.7 and resolver 8.8.8.8');
    const kept = [
      '2026-10-15 08:22:01 Colitu VPN 5.9.1+57, Xray 26.10.10',
      '2026-10-15T08:22:01.123Z core_started',
      'loopback 127.0.0.1 and ::1, any 0.0.0.0',
      'wifi aa:bb:cc:dd:ee:ff',
    ];
    for (final line in kept) {
      expect(mask(line), line);
    }
  });

  test('a known host under a two-label suffix keeps only its own domain', () {
    String maskUk(String text) => SiteRedaction.mask(text, knownHosts: const ['node.example.co.uk']);
    expect(maskUk('lookup other.example.co.uk'), 'lookup other.example.co.uk');
    expect(maskUk('lookup www.bbc.co.uk'), 'lookup <site>');
  });
}
