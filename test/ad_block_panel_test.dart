import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The ad-blocking resolvers come from the panel's bootstrap (`ad_block.doh`);
/// an empty or missing list never replaces the one already stored.
void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    ColituAdBlock.resetForTest();
  });

  Map<String, dynamic> bootstrap(Object? adBlock) => {
    'user': {'id': 'u1'},
    'entitlement': {'status': 'active', 'plan': 'colitu-free'},
    'ad_block': ?adBlock,
  };

  test(
    'the bootstrap list is read (strings only; https is checked when kept)',
    () {
      final status = VPNStatus.fromJson(
        bootstrap({
          'doh': [
            'https://dns-a.example.test/dns-query',
            'http://plain.example.test/dns-query',
            5,
          ],
        }),
      );
      expect(status.adBlockDoh, [
        'https://dns-a.example.test/dns-query',
        'http://plain.example.test/dns-query',
      ]);
      expect(VPNStatus.fromJson(bootstrap(null)).adBlockDoh, isNull);
    },
  );

  test('a list replaces the stored one; empty or missing keeps it', () async {
    expect(
      await ColituAdBlock.remember([
        'https://dns-a.example.test/dns-query',
        'http://plain.example.test/dns-query',
      ]),
      isTrue,
    );
    expect(ColituAdBlock.dohServers, ['https://dns-a.example.test/dns-query']);
    expect(ColituAdBlock.available, isTrue);

    expect(await ColituAdBlock.remember(const []), isFalse);
    expect(await ColituAdBlock.remember(null), isFalse);
    expect(await ColituAdBlock.remember(['http://x.example.test']), isFalse);
    expect(ColituAdBlock.dohServers, ['https://dns-a.example.test/dns-query']);

    // Kept across starts.
    ColituAdBlock.resetForTest();
    await ColituAdBlock.load();
    expect(ColituAdBlock.dohServers, ['https://dns-a.example.test/dns-query']);
    expect(
      await PreferencesKey().readColituAdBlockDoh(),
      'https://dns-a.example.test/dns-query',
    );

    expect(
      await ColituAdBlock.remember(['https://dns-b.example.test/dns-query']),
      isTrue,
    );
    expect(ColituAdBlock.dohServers, ['https://dns-b.example.test/dns-query']);
  });

  test(
    'local and private resolver addresses are dropped, at most 8 (I4-04)',
    () {
      final list = ColituAdBlock.parse(
        [
          'https://127.0.0.1/dns-query',
          'https://192.168.1.1/dns-query',
          'https://[::1]/dns-query',
          'https://localhost/dns-query',
          'https://router/dns-query',
          'https://dns.local/dns-query',
          'https://8.8.8.8/dns-query',
          'https://dns-a.example.test/dns-query',
          'https://dns-a.example.test/dns-query',
          for (var i = 0; i < 10; i++) 'https://dns$i.example.test/dns-query',
        ].join(','),
      );
      expect(list.take(2), [
        'https://8.8.8.8/dns-query',
        'https://dns-a.example.test/dns-query',
      ]);
      expect(list, hasLength(ColituAdBlock.maxServers));
      expect(list.toSet().length, list.length);
    },
  );
}
