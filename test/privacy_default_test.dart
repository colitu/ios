import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Privacy mode is the default for new installs only.
void main() {
  group('colituPrivacyDefaultFor', () {
    test('no stored Colitu state is a fresh install: on', () {
      expect(
        PreferencesKey.colituPrivacyDefaultFor(
          const [],
          hasSession: false,
        ),
        isTrue,
      );
      expect(
        PreferencesKey.colituPrivacyDefaultFor(
          const ['flutter.something_else'],
          hasSession: false,
        ),
        isTrue,
      );
    });

    test('any Colitu preference means an existing install: off', () {
      expect(
        PreferencesKey.colituPrivacyDefaultFor(
          const ['colituLanguage'],
          hasSession: false,
        ),
        isFalse,
      );
    });

    test('a stored session means an existing install: off', () {
      expect(
        PreferencesKey.colituPrivacyDefaultFor(const [], hasSession: true),
        isFalse,
      );
    });
  });

  group('resolveColituPrivacyDefault', () {
    // PreferencesKey is a singleton that keeps the first platform instance,
    // so one instance serves every test and is reset by seed().
    setUpAll(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    Future<void> seed(Map<String, bool> values) async {
      final prefs = SharedPreferencesAsync();
      await prefs.clear();
      for (final e in values.entries) {
        await prefs.setBool(e.key, e.value);
      }
    }

    test('fresh install stores true, once', () async {
      await seed({});
      var asked = 0;
      Future<bool> noSession() async {
        asked++;
        return false;
      }

      await PreferencesKey().resolveColituPrivacyDefault(hasSession: noSession);
      expect(await PreferencesKey().readColituPrivacyMode(), isTrue);
      expect(asked, 1);

      // The user turns it off; a later start must not turn it back on.
      await PreferencesKey().saveColituPrivacyMode(false);
      await PreferencesKey().resolveColituPrivacyDefault(hasSession: noSession);
      expect(await PreferencesKey().readColituPrivacyMode(), isFalse);
      expect(asked, 1);
    });

    test('existing install (Colitu preference) stores false', () async {
      await seed({'colituKeychainThisDevice01': true});
      await PreferencesKey().resolveColituPrivacyDefault(
        hasSession: () async => fail('keys already say existing'),
      );
      expect(await SharedPreferencesAsync().getBool('colituPrivacyMode'), isFalse);
    });

    test('existing install (only a stored session) stores false', () async {
      await seed({});
      await PreferencesKey().resolveColituPrivacyDefault(
        hasSession: () async => true,
      );
      expect(await SharedPreferencesAsync().getBool('colituPrivacyMode'), isFalse);
    });

    test('an already stored choice is left alone', () async {
      await seed({'colituPrivacyMode': true});
      await PreferencesKey().resolveColituPrivacyDefault(
        hasSession: () async => fail('already stored'),
      );
      expect(await PreferencesKey().readColituPrivacyMode(), isTrue);
    });
  });
}
