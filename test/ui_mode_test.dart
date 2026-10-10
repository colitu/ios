import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/ui_mode.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

VPNServer _server(String id) => VPNServer.fromJson({
  'id': id,
  'name': id,
  'countryCode': 'DE',
  'available': true,
});

final _route = VPNServer.parseMultihop([
  {
    'id': 'r1',
    'name': 'FI → DE',
    'country': 'DE',
    'multihop': true,
    'entry': {'node_id': 'n-fi', 'country': 'FI'},
    'exit': {'node_id': 'n-de', 'country': 'DE'},
  },
]).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('default mode', () {
    test('fresh install is Simple, anything earlier is Advanced', () {
      expect(
        PreferencesKey.colituAdvancedDefaultFor(const [], hasSession: false),
        isFalse,
      );
      expect(
        PreferencesKey.colituAdvancedDefaultFor(const [
          'colituAutoConnect',
        ], hasSession: false),
        isTrue,
      );
      expect(
        PreferencesKey.colituAdvancedDefaultFor(const [], hasSession: true),
        isTrue,
      );
    });

    group('stored on the first start', () {
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

      Future<bool> noSession() async => false;

      test('new install: Simple, kept once the user changes it', () async {
        await seed({});
        await PreferencesKey().resolveColituPrivacyDefault(hasSession: noSession);
        expect(await PreferencesKey().readColituAdvancedMode(), isFalse);
        // Privacy mode keeps its fresh-install default next to it.
        expect(await PreferencesKey().readColituPrivacyMode(), isTrue);

        await PreferencesKey().saveColituAdvancedMode(true);
        await PreferencesKey().resolveColituPrivacyDefault(hasSession: noSession);
        expect(await PreferencesKey().readColituAdvancedMode(), isTrue);
      });

      test('update from a version that stored privacy mode: Advanced', () async {
        await seed({'colituPrivacyMode': true});
        await PreferencesKey().resolveColituPrivacyDefault(
          hasSession: () async => fail('already known as an update'),
        );
        expect(await PreferencesKey().readColituAdvancedMode(), isTrue);
      });

      test('update with only a stored session: Advanced', () async {
        await seed({});
        await PreferencesKey().resolveColituPrivacyDefault(
          hasSession: () async => true,
        );
        expect(await PreferencesKey().readColituAdvancedMode(), isTrue);
      });
    });
  });

  group('Simple mode forces the automatic choices', () {
    test('pinned multihop route gives way to the automatic pick', () {
      expect(
        ColituUiMode.automaticTarget(
          advanced: false,
          autoSelection: false,
          selected: _route,
        ),
        isTrue,
      );
      expect(
        ColituUiMode.automaticTarget(
          advanced: true,
          autoSelection: false,
          selected: _route,
        ),
        isFalse,
      );
      // A pinned country stays pinned in Simple mode.
      expect(
        ColituUiMode.automaticTarget(
          advanced: false,
          autoSelection: false,
          selected: _server('de'),
        ),
        isFalse,
      );
    });

    test('rotation (VLESS only) does not apply; warm spare is on', () {
      expect(
        ColituUiMode.rotationApplies(advanced: false, rotationActive: true),
        isFalse,
      );
      expect(
        ColituUiMode.rotationApplies(advanced: true, rotationActive: true),
        isTrue,
      );
      expect(ColituUiMode.warmSpareOn(advanced: false, setting: false), isTrue);
      expect(ColituUiMode.warmSpareOn(advanced: true, setting: false), isFalse);
    });

    test('the controller connects to the automatic pick, keeps the route', () {
      final de = _server('de');
      final c = ColituConnectionController()
        ..servers = [de]
        ..multihopServers = [_route]
        ..autoSelection = false
        ..selectedServer = _route;
      expect(c.effectiveServer, same(_route));
      expect(c.hiddenSettingsActive, isFalse);

      c.advancedMode = false;
      expect(c.effectiveServer, same(de));
      expect(c.automaticTarget, isTrue);
      expect(c.selectedServer, same(_route), reason: 'back in Advanced mode');
      expect(c.hiddenSettingsActive, isTrue);
      c.dispose();
    });
  });
}
