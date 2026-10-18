import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/colitu_system_doh.dart';
import 'package:colitu_vpn/core/model/tun_json.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The system DNS over DoH (5.9.4): bootstrap `dns.doh` parsing and which
/// resolvers the tunnel start gets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    ColituSystemDoh.resetForTest();
    ColituAdBlock.resetForTest();
  });

  test('dns.doh is read from the bootstrap, strings only', () {
    expect(ColituSystemDoh.serversOf({}), isNull);
    expect(
      ColituSystemDoh.serversOf({
        'dns': {
          'doh': ['https://a.example.com:3443/dns-query/unfiltered', 3],
        },
      }),
      ['https://a.example.com:3443/dns-query/unfiltered'],
    );
    expect(
      ColituSystemDoh.serversOf({
        'data': {
          'dns': {'doh': <String>[]},
        },
      }),
      isEmpty,
    );
  });

  test('remember keeps public https resolvers and an explicit empty list clears them', () async {
    expect(await ColituSystemDoh.remember(['https://a.example.com:3443/dns-query/unfiltered', 'http://b.example.com/dns-query', 'https://127.0.0.1/dns-query']), isTrue);
    expect(ColituSystemDoh.unfiltered, ['https://a.example.com:3443/dns-query/unfiltered']);
    expect(await ColituSystemDoh.remember(null), isFalse, reason: 'an older panel keeps the list');
    expect(ColituSystemDoh.unfiltered, isNotEmpty);
    expect(await ColituSystemDoh.remember(const []), isTrue);
    expect(ColituSystemDoh.unfiltered, isEmpty);
  });

  test('ad blocking on uses the ad-blocking resolvers, off the unfiltered ones', () async {
    await ColituSystemDoh.remember(['https://a.example.com:3443/dns-query/unfiltered']);
    await ColituAdBlock.remember(['https://a.example.com:3443/dns-query']);
    expect(ColituSystemDoh.urlsFor(adBlock: false), ['https://a.example.com:3443/dns-query/unfiltered']);
    expect(ColituSystemDoh.urlsFor(adBlock: true), ['https://a.example.com:3443/dns-query']);
  });

  test('the list survives a restart', () async {
    await ColituSystemDoh.remember(['https://a.example.com:3443/dns-query/unfiltered']);
    ColituSystemDoh.resetForTest();
    await ColituSystemDoh.load();
    expect(ColituSystemDoh.unfiltered, ['https://a.example.com:3443/dns-query/unfiltered']);
  });

  test('dohUrls reach the tunnel start request and back', () {
    final tun = TunJson('198.18.0.2', null, null, null, null, null, null, null, null, null, null, null, null, null)
      ..dohUrls = ['https://a.example.com:3443/dns-query'];
    final json = tun.toJson();
    expect(json['dohUrls'], ['https://a.example.com:3443/dns-query']);
    expect(TunJson.fromJson(json).dohUrls, ['https://a.example.com:3443/dns-query']);
    expect((TunJson('198.18.0.2', null, null, null, null, null, null, null, null, null, null, null, null, null)).toJson().containsKey('dohUrls'), isFalse);
  });
}
