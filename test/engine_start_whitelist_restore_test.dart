import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/colitu_ac_events.dart';
import 'package:colitu_vpn/colitu/services/colitu_lm.dart';
import 'package:colitu_vpn/colitu/services/colitu_lm_engine.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/stall_watch.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

String _uuid(String tail) => '00000000-0000-4000-8000-${tail.padLeft(12, '0')}';

VPNServer _server(String tail, String country, {bool whitelist = false}) => VPNServer(
  id: _uuid(tail),
  name: tail,
  country: country,
  flagCode: country,
  status: 'online',
  available: true,
  locked: false,
  isPremium: false,
  isFree: true,
  isRecommended: false,
  host: '$tail.example.test',
  port: 443,
  whitelistOk: whitelist,
  protocols: const ['vless-reality'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('engine not started', () {
    final start = DateTime.utc(2026, 11, 3, 10, 0, 5);

    test('a stability log line since the start is a sign of life', () {
      String line(String at) =>
          '{"event":"connection_state_changed","reason":"startTunnel","timestamp":"$at"}';
      expect(ColituVPNService.stabilityLogShowsStart([line('2026-11-03T10:00:06Z')], start), isTrue);
      // Second precision: two seconds of slack.
      expect(ColituVPNService.stabilityLogShowsStart([line('2026-11-03T10:00:04Z')], start), isTrue);
      expect(ColituVPNService.stabilityLogShowsStart([line('2026-11-03T09:59:50Z')], start), isFalse);
      expect(ColituVPNService.stabilityLogShowsStart(['not json', ''], start), isFalse);
      expect(ColituVPNService.stabilityLogShowsStart(const [], start), isFalse);
    });

    test('the user is asked to restart the phone, in every language', () {
      final before = ColituLoc.I.language;
      addTearDown(() => ColituLoc.I.setLanguage(before, persist: false));
      final expected = {
        'tr': 'Bağlantı servisi başlatılamadı. Telefonu yeniden başlatıp tekrar deneyin.',
        'en': 'The connection service could not be started. Restart your phone and try again.',
        'ru': 'Не удалось запустить службу подключения. Перезагрузите телефон и попробуйте снова.',
      };
      for (final language in ColituLoc.languages) {
        ColituLoc.I.setLanguage(language, persist: false);
        expect(
          colituErrorMessage(const ColituEngineNotStartedException()),
          expected[language],
          reason: language,
        );
      }
    });

    test('no server vote: the reason is other, the code is ENGINE_NOT_STARTED', () {
      expect(ColituAcEvents.reasonOfError(const ColituEngineNotStartedException()), 'other');
      expect(ColituEngineNotStartedException.code, 'ENGINE_NOT_STARTED');
    });
  });

  group('whitelist mode after a restart', () {
    final now = DateTime(2026, 11, 3, 10);

    test('restore rule', () {
      ({bool on, DateTime checkedAt, String network}) saved(bool on, Duration age, String network) =>
          (on: on, checkedAt: now.subtract(age), network: network);
      expect(ColituWhitelist.restore(null, 'wifi|a', now), ColituWhitelistRestore.none);
      expect(
        ColituWhitelist.restore(saved(false, Duration.zero, 'wifi|a'), 'wifi|a', now),
        ColituWhitelistRestore.none,
      );
      expect(
        ColituWhitelist.restore(saved(true, const Duration(minutes: 5), 'wifi|a'), 'wifi|a', now),
        ColituWhitelistRestore.on,
      );
      expect(
        ColituWhitelist.restore(saved(true, const Duration(minutes: 6), 'wifi|a'), 'wifi|a', now),
        ColituWhitelistRestore.recheck,
      );
      expect(
        ColituWhitelist.restore(saved(true, Duration.zero, 'cellular|b'), 'wifi|a', now),
        ColituWhitelistRestore.recheck,
      );
      expect(
        ColituWhitelist.restore(saved(true, const Duration(minutes: -1), 'wifi|a'), 'wifi|a', now),
        ColituWhitelistRestore.recheck,
      );
      final round = ColituWhitelist.decodeSaved(
        ColituWhitelist.encodeSaved(saved(true, const Duration(minutes: 2), 'wifi|a')),
      )!;
      expect(round.on, isTrue);
      expect(round.network, 'wifi|a');
      expect(round.checkedAt, now.subtract(const Duration(minutes: 2)));
      expect(ColituWhitelist.decodeSaved('{"on":true}'), isNull);
      expect(ColituWhitelist.decodeSaved('junk'), isNull);
    });

    group('controller', () {
      setUp(() {
        SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
        ColituAc4Switch.setRemote(true);
      });
      tearDown(() => ColituAc4Switch.setRemote(false));

      Future<String> network() async => colituNetworkKey(await ColituStallWatch.linkKind(), '');

      test('a recent mode on this network is on again without a check', () async {
        await PreferencesKey().saveColituWhitelistState(
          ColituWhitelist.encodeSaved((
            on: true,
            checkedAt: DateTime.now().subtract(const Duration(minutes: 2)),
            network: await network(),
          )),
        );
        final c = ColituConnectionController()..servers = [_server('3', 'DE')];
        addTearDown(c.dispose);
        var checks = 0;
        c.whitelistReachable = (host, port, timeout) async {
          checks++;
          return false;
        };
        await c.restoreWhitelistMode();
        expect(c.whitelistMode, isTrue);
        expect(checks, 0);
      });

      test('an old mode is checked again; the result is saved', () async {
        await PreferencesKey().saveColituWhitelistState(
          ColituWhitelist.encodeSaved((
            on: true,
            checkedAt: DateTime.now().subtract(const Duration(minutes: 30)),
            network: await network(),
          )),
        );
        final c = ColituConnectionController()
          ..servers = [_server('3', 'DE')]
          ..debugClientCountry = 'RU';
        addTearDown(c.dispose);
        var checks = 0;
        // The foreign hosts answer: no whitelist.
        c.whitelistReachable = (host, port, timeout) async {
          checks++;
          return true;
        };
        await c.restoreWhitelistMode();
        expect(checks, greaterThan(0));
        expect(c.whitelistMode, isFalse);
        await Future<void>.delayed(Duration.zero);
        final saved = ColituWhitelist.decodeSaved(await PreferencesKey().readColituWhitelistState());
        expect(saved?.on, isFalse);
      });

      test('nothing saved: nothing happens', () async {
        final c = ColituConnectionController()..servers = [_server('3', 'DE')];
        addTearDown(c.dispose);
        var checks = 0;
        c.whitelistReachable = (host, port, timeout) async {
          checks++;
          return false;
        };
        await c.restoreWhitelistMode();
        expect(c.whitelistMode, isFalse);
        expect(checks, 0);
      });
    });
  });

  group('the recommended entry follows the automatic order', () {
    tearDown(() => ColituAc4Switch.setRemote(false));

    // DE answers fastest, but the panel's priors say it fails here.
    final servers = [_server('3', 'DE'), _server('4', 'NL')];
    final model = ColituLmModel(
      version: 1,
      country: 'TR',
      explore: 0,
      priors: {
        'TR': {
          _uuid('3'): {
            '*': [1.0, 19.0],
          },
          _uuid('4'): {
            '*': [19.0, 1.0],
          },
        },
      },
    );

    test('AC4 on: the Colitu LM order; off: the AC 3 order', () async {
      final c = ColituConnectionController()
        ..servers = servers
        ..latencyProbe = ((host, port) async => host.startsWith('3') ? 20 : 200)
        ..tunnelLatencyProbe = null
        ..debugClientCountry = 'TR';
      addTearDown(c.dispose);
      await c.measurePings();
      c.debugSetAcModel(model, DateTime.now());

      ColituAc4Switch.setRemote(false);
      expect(c.rankedServers.first.id, _uuid('3'));
      ColituAc4Switch.setRemote(true);
      expect(c.rankedServers.first.id, _uuid('4'));
    });
  });
}
