import 'package:flutter_test/flutter_test.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/setting/dns_server_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';

const _servers = [
  'https://se.example.test:3443/dns-query',
  'https://uk.example.test:3443/dns-query',
  'https://pl.example.test:3443/dns-query',
];

void main() {
  test('ad blocking swaps the general resolvers for the Colitu DoH servers', () {
    final state = XraySettingState();
    final general = DnsServerState()
      ..address = 'https://1.1.1.1/dns-query'
      ..tag = 'default-dns';
    final local = DnsServerState()
      ..address = 'tcp://9.9.9.9'
      ..domains = ['geosite:private']
      ..tag = 'local-dns';
    state.dns.servers = [general, local];

    ColituAdBlock.applyTo(state, servers: _servers);

    final addresses = state.dns.servers.map((s) => s.address).toList();
    expect(addresses.take(3), _servers);
    expect(state.dns.servers.take(3).every((s) => s.tag == 'default-dns'), isTrue);
    // Resolvers scoped to listed domains stay.
    expect(addresses.last, 'tcp://9.9.9.9');
    expect(addresses, isNot(contains('https://1.1.1.1/dns-query')));
  });

  test('a stalled DoH server times out after 3 s and a plain resolver follows', () {
    final state = XraySettingState();
    state.dns.servers = [
      DnsServerState()
        ..address = 'https://1.1.1.1/dns-query'
        ..tag = 'default-dns',
      DnsServerState()
        ..address = 'tcp://9.9.9.9'
        ..domains = ['geosite:private']
        ..tag = 'local-dns',
    ];

    ColituAdBlock.applyTo(state, servers: _servers);

    final json = state.dns.xrayJson.toJson();
    final servers = [
      for (final server in json['servers'] as List)
        Map<String, dynamic>.from(server as Map),
    ];
    expect(servers.map((s) => s['address']), [
      ..._servers,
      ColituAdBlock.fallbackResolver,
      'tcp://9.9.9.9',
    ]);
    for (final doh in servers.take(3)) {
      expect(doh['timeoutMs'], ColituAdBlock.dohTimeoutMs);
    }
    // The fallback answers any domain, after every DoH server failed.
    expect(servers[3]['domains'], isNull);
    expect(servers[3]['tag'], 'default-dns');
    expect(servers[3].containsKey('timeoutMs'), isFalse);
    expect(json['disableFallback'], isNull);
  });

  test("the app's own plain resolver is kept as the fallback", () {
    final state = XraySettingState();
    state.dns.servers = [DnsServerState()..address = 'tcp://8.8.8.8'];
    ColituAdBlock.applyTo(state, servers: _servers);
    expect(state.dns.servers.last.address, 'tcp://8.8.8.8');

    final local = XraySettingState();
    local.dns.servers = [DnsServerState()..address = 'localhost'];
    ColituAdBlock.applyTo(local, servers: _servers);
    // Never the system resolver outside the tunnel.
    expect(local.dns.servers.last.address, ColituAdBlock.fallbackResolver);
  });

  test('timeoutMs survives a read back from the written JSON', () {
    final written = (DnsServerState()
          ..address = 'https://dns.example.test/dns-query'
          ..timeoutMs = 3000)
        .xrayJson
        .toJson();
    expect(written['timeoutMs'], 3000);
    final read = DnsServerState()
      ..readFromDnsServer(XrayDnsServer.fromJson(written));
    expect(read.timeoutMs, 3000);
    expect(DnsServerState().xrayJson.toJson().containsKey('timeoutMs'), isFalse);
  });

  test('the build-time list keeps https URLs in order', () {
    expect(
      ColituAdBlock.parse(' https://a.example.test/dns-query, ,http://b.example.test,https://c.example.test/dns-query'),
      ['https://a.example.test/dns-query', 'https://c.example.test/dns-query'],
    );
    expect(ColituAdBlock.parse(''), isEmpty);
  });

  test('without servers the resolvers stay', () {
    final state = XraySettingState();
    state.dns.servers = [DnsServerState()..address = 'https://1.1.1.1/dns-query'];
    ColituAdBlock.applyTo(state, servers: const []);
    expect(state.dns.servers.single.address, 'https://1.1.1.1/dns-query');
  });

  test('only the nodes that run the DNS servers are tagged', () {
    expect(ColituAdBlock.hostsDns('se.example.test', servers: _servers), isTrue);
    expect(ColituAdBlock.hostsDns(' UK.example.test ', servers: _servers), isTrue);
    expect(ColituAdBlock.hostsDns('fi.example.test', servers: _servers), isFalse);
    expect(ColituAdBlock.hostsDns(null, servers: _servers), isFalse);
  });
}
