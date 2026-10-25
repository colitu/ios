import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_client.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colitu Passport v2: the account's state from the server, the cache, the
/// one-time import of this device's v1 progress and the server's events.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 24, 12);
  late ColituPassport p;
  late _FakeApi api;
  late PassportClient client;

  Map<String, Object?> sample({List<Map<String, Object?>>? stamps, int unseen = 0}) => {
    'data': {
      'collector_no': '992562',
      'nickname': 'Ali',
      'title_id': 'nordic-master',
      'cover_id': 'classic',
      'tester': false,
      'premium': true,
      'chapter2_open': false,
      'companion': true,
      'today': {'day': ColituPassport.dayKey(now), 'minutes': 34, 'pieces': 1, 'next_piece_at_minute': 60},
      'run': {'country': 'SE', 'minutes': 3},
      'stamps':
          stamps ??
          [
            {'country': 'SE', 'unlocked_at': '2026-10-21T10:00:00Z', 'pieces': 13, 'level': 'silver', 'mastered': false},
            {'country': 'uk', 'unlocked_at': '2026-10-22T10:00:00Z', 'pieces': 2, 'level': 'bronze', 'mastered': false},
          ],
      'achievements': [
        {'id': 'first', 'earned_at': '2026-10-21T10:00:00Z'},
        {'id': 'nordic-master', 'earned_at': '2026-10-23T10:00:00Z'},
      ],
      'collections': [
        {'id': 'gold-rush', 'earned_at': '2026-10-23T10:00:00Z'},
      ],
      'covers': ['classic', 'premium'],
      'weekly': {
        'week': '2026-W43',
        'goals': [
          {'id': 'new_country', 'target': 1, 'progress': 1, 'done': true},
          {'id': 'pieces', 'target': 4, 'progress': 2, 'done': false},
          {'id': 'share', 'target': 1, 'progress': 0, 'done': false},
        ],
      },
      'expeditions_done': 2,
      'unseen_events': unseen,
      'updated_at': '2026-10-24T09:00:00Z',
    },
  };

  setUp(() {
    p = ColituPassport(store: PassportStore(), clock: () => now);
    api = _FakeApi(PassportServerState.parse(sample())!);
    client = PassportClient(api: api, deviceId: () async => 'dev-1', passport: () => p);
  });

  group('server state', () {
    test('parses the contract and fills the cache the screens read', () {
      PassportServerState.parse(sample())!.applyTo(p);
      expect(p.fromServer, isTrue);
      expect(p.progressOf('SE').pieces, 13);
      expect(p.progressOf('SE').level, StampLevel.silver);
      expect(p.progressOf('GB').unlocked, isTrue, reason: 'UK is Great Britain');
      expect(p.count, 2);
      expect(p.today, (34, 1));
      expect(p.goals.collectorNo, '992562');
      expect(p.goals.nickname, 'Ali');
      expect(p.goals.title, 'nordic_master');
      expect(p.goals.achieved(PassportAchievement.nordicMaster), isTrue);
      // The server's list decides, not what the stamps would suggest.
      expect(p.goals.achieved(PassportAchievement.globetrotter), isFalse);
      expect(p.goals.completed(PassportCollection.goldRush), isTrue);
      expect(p.goals.completed(PassportCollection.nordic), isFalse);
      expect(p.goals.earnedAt('a_first'), DateTime.utc(2026, 10, 21, 10).millisecondsSinceEpoch);
      expect(p.social.companion, isTrue);
      expect(p.weekly.goals(), [ExpeditionGoal.newCountry, ExpeditionGoal.pieces, ExpeditionGoal.share]);
      expect(p.weekly.goals().map(p.weekly.progress), [1, 2, 0]);
      expect(p.weekly.done(ExpeditionGoal.newCountry), isTrue);
      expect(p.weekly.total, 2);
    });

    test('a stamp the server no longer has leaves the cache', () {
      p.store
        ..setInt('t_FI', 5)
        ..setInt('p_FI', 3);
      PassportServerState.parse(sample())!.applyTo(p);
      expect(p.progressOf('FI').unlocked, isFalse);
      expect(p.progressOf('FI').pieces, 0);
    });

    test('offline: the cache shows the last state after a restart', () {
      PassportServerState.parse(sample())!.applyTo(p);
      final reopened = ColituPassport(store: PassportStore(p.store.snapshot()), clock: () => now);
      expect(reopened.progressOf('SE').pieces, 13);
      expect(reopened.goals.achieved(PassportAchievement.nordicMaster), isTrue);
      expect(reopened.weekly.total, 2);
    });

    test('a week later the stored goals are not shown as this week\'s', () {
      PassportServerState.parse(sample())!.applyTo(p);
      final later = ColituPassport(store: p.store, clock: () => now.add(const Duration(days: 7)));
      expect(later.weekly.goals(), PassportWeekly.goalsOf(now.add(const Duration(days: 7))));
      expect(later.weekly.goals().map(later.weekly.progress), [0, 0, 0]);
    });

    test('junk is not a state', () {
      expect(PassportServerState.parse(null), isNull);
      expect(PassportServerState.parse('x'), isNull);
      expect(PassportServerState.parse({'data': {}}), isNull);
    });
  });

  group('import of the v1 progress', () {
    void v1Progress() {
      p.store
        ..setInt('t_SE', DateTime.utc(2026, 10, 21).millisecondsSinceEpoch)
        ..setInt('p_SE', 5)
        ..setInt('t_NO', DateTime.utc(2026, 10, 22).millisecondsSinceEpoch)
        ..setInt('expeditions_done', 1)
        ..setString('nick', 'Ayşe')
        ..setString('title', 'first');
    }

    test('sent once, before the server state replaces the cache', () async {
      v1Progress();
      expect(await client.refresh(), isTrue);
      expect(api.calls.first, 'import');
      final body = api.imported!;
      expect(body['device_id'], 'dev-1');
      expect(body['stamps'], [
        {'country': 'SE', 'pieces': 5, 'unlocked_at': '2026-10-21T00:00:00.000Z'},
        {'country': 'NO', 'pieces': 0, 'unlocked_at': '2026-10-22T00:00:00.000Z'},
      ]);
      expect(body['achievements'], contains('first'));
      expect(body['expeditions_done'], 1);
      expect(body['nickname'], 'Ayşe');
      expect(body['title_id'], 'first');
      expect(p.store.getBool(PassportClient.importedKey), isTrue);
      expect(p.progressOf('SE').pieces, 13, reason: 'the server state is shown');

      api.calls.clear();
      await client.refresh();
      expect(api.calls, isNot(contains('import')));
    });

    test('409 PASSPORT_ALREADY_IMPORTED counts as done', () async {
      v1Progress();
      api.importError = const APIException(
        APIErrorCode.unknown,
        'imported',
        statusCode: 409,
        backendCode: 'PASSPORT_ALREADY_IMPORTED',
      );
      expect(await client.refresh(), isTrue);
      expect(p.store.getBool(PassportClient.importedKey), isTrue);
      expect(p.progressOf('SE').pieces, 13);
    });

    test('no network: the v1 progress stays until it reached the account', () async {
      v1Progress();
      api.importError = const APIException(APIErrorCode.networkUnavailable, 'offline');
      expect(await client.refresh(), isFalse);
      expect(api.calls, ['import']);
      expect(p.store.getBool(PassportClient.importedKey), isFalse);
      expect(p.progressOf('SE').pieces, 5);
      expect(p.fromServer, isFalse);
    });

    test('nothing to import: no request, just the state', () async {
      expect(await client.refresh(), isTrue);
      expect(api.calls, isNot(contains('import')));
      expect(api.calls, contains('state'));
      expect(p.store.getBool(PassportClient.importedKey), isTrue);
    });
  });

  group('events and reveals', () {
    test('unseen events become reveals in id order; unknown kinds are acked silently', () async {
      api.current = PassportServerState.parse(sample(unseen: 4))!;
      api.events = PassportServerEvent.parseList({
        'data': [
          {'id': 14, 'kind': 'level_up', 'payload': {'country': 'SE', 'level': 'silver'}},
          {'id': 12, 'kind': 'stamp_unlocked', 'payload': {'country': 'SE'}},
          {'id': 13, 'kind': 'piece', 'payload': {'country': 'SE', 'pieces': 12}},
          {'id': 15, 'kind': 'confetti', 'payload': {}},
          {'id': 16, 'kind': 'achievement', 'payload': {'id': 'nordic-master'}},
          {'id': 17, 'kind': 'weekly_done', 'payload': {'goal_id': 'new_country'}},
          {'id': 18, 'kind': 'companion', 'payload': {}},
          {'id': 19, 'kind': 'chapter_opened', 'payload': {'chapter': 2}},
        ],
      });
      await client.refresh();
      final reveals = client.takeReveals();
      expect(reveals.map((r) => r.id), [12, 13, 14, 15, 16, 17, 18, 19]);
      expect(reveals.map((r) => r.event), [
        const StampEvent.unlocked('SE'),
        const StampEvent.piece('SE', 12),
        const StampEvent.levelUp('SE', StampLevel.silver),
        null,
        const StampEvent.achieved('nordic_master'),
        const StampEvent.expedition('new_country'),
        const StampEvent.special('companion'),
        const StampEvent.chapter('2'),
      ]);
      // Not queued twice while they wait for the ack.
      await client.refresh();
      expect(client.takeReveals(), isEmpty);
      await client.ack(reveals.last.id);
      expect(api.ackedThrough, 19);
    });

    test('no unseen events: the event list is not fetched', () async {
      await client.refresh();
      expect(api.calls, isNot(contains('events')));
      expect(client.takeReveals(), isEmpty);
    });
  });

  group('admin changes', () {
    Map<String, Object?> trimmed() {
      final root = sample();
      final data = (root['data'] as Map).cast<String, Object?>();
      return {
        'data': {
          ...data,
          'stamps': [
            {'country': 'SE', 'unlocked_at': '2026-10-21T10:00:00Z', 'pieces': 13},
          ],
          'achievements': [
            {'id': 'first', 'earned_at': '2026-10-21T10:00:00Z'},
          ],
          'collections': [],
          'companion': false,
          'title_id': null,
          // Still chosen on the server, but its set was taken away.
          'cover_id': 'nordic',
          'today': null,
        },
      };
    }

    test('whatever the server took away leaves the cache; cover and title fall back', () {
      PassportServerState.parse(sample())!.applyTo(p);
      p.store
        ..setString('srv_col', 'nordic')
        ..setString('cover', 'nordic');
      expect(p.goals.activeCover(false), CoverTheme.nordic);
      PassportServerState.parse(trimmed())!.applyTo(p);
      expect(p.progressOf('GB').unlocked, isFalse);
      expect(p.goals.achieved(PassportAchievement.nordicMaster), isFalse);
      expect(p.goals.completed(PassportCollection.goldRush), isFalse);
      expect(p.social.companion, isFalse);
      expect(p.goals.titleOf(p.goals.title), isNull);
      expect(p.goals.activeCover(false), CoverTheme.classic);
      expect(p.goals.activeCover(true), CoverTheme.premium);
      // No day in the answer: nothing about today.
      expect(p.todayKnown, isFalse);
      expect(p.today, (0, 0));
    });

    test('revoke events play nothing and are marked for one notice; unknown kinds are silent', () async {
      api.current = PassportServerState.parse(sample(unseen: 3))!;
      api.events = PassportServerEvent.parseList({
        'data': [
          {'id': 30, 'kind': 'stamp_revoked', 'payload': {'country': 'GB'}},
          {'id': 31, 'kind': 'stamp_unlocked', 'payload': {'country': 'SE', 'source': 'admin'}},
          {'id': 32, 'kind': 'passport_reset', 'payload': {}},
          {'id': 33, 'kind': 'hologram_added', 'payload': {}},
        ],
      });
      await client.refresh();
      final reveals = client.takeReveals();
      expect(reveals.map((r) => r.event), [null, const StampEvent.unlocked('SE'), null, null]);
      expect(reveals.map((r) => r.revoked), [true, false, true, false]);
    });

    testWidgets('the shell acks the batch and says once that the passport changed', (tester) async {
      await ColituLoc.I.setLanguage('tr', persist: false);
      ColituPassport.I = p;
      api.current = PassportServerState.parse(sample(unseen: 2))!;
      api.events = PassportServerEvent.parseList({
        'data': [
          {'id': 40, 'kind': 'achievement_revoked', 'payload': {'id': 'globe'}},
          {'id': 41, 'kind': 'companion_revoked', 'payload': {}},
        ],
      });
      final c = ColituConnectionController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PassportHost(controller: c, client: client, child: const Scaffold(body: SizedBox())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Pasaportun güncellendi'), findsOneWidget);
      expect(api.ackedThrough, 41);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('home card goal', () {
    setUp(() => ColituLoc.I.setLanguage('en', persist: false));

    test('"pieces collected" never shows without the server reporting today', () {
      ColituPassport.I = p;
      for (final s in ColituPassport.stamps) {
        p.store
          ..setInt('t_${s.code}', 1)
          ..setInt('p_${s.code}', 48);
      }
      // Not loaded from the server yet.
      expect(nextGoal().text, isNot(ColituLoc.I['passport.goal.done']));
      // Loaded, but no day in the answer.
      p.store.setInt('srv_at', 1);
      expect(nextGoal().text, ColituLoc.I['passport.goal.mastered']);
      // The server says both pieces of today are in.
      p.store
        ..setString('day', ColituPassport.dayKey(now))
        ..setInt('day_min', 70)
        ..setInt('day_pieces', 2);
      expect(nextGoal().text, ColituLoc.I['passport.goal.done']);
    });

    test('an empty passport asks for the first stamp', () {
      ColituPassport.I = p;
      expect(nextGoal().text, ColituLoc.I['passport.goal.first']);
    });
  });

  test('the time zone is sent once, then again when it changes', () async {
    await client.refresh();
    await client.refresh();
    expect(api.profiles.where((f) => f.containsKey('tz_offset_min')), hasLength(1));
    expect(api.profiles.single['tz_offset_min'], DateTime.now().timeZoneOffset.inMinutes);
  });

  test('a share goes to the server', () async {
    await client.share();
    expect(api.calls, ['share']);
  });

  test('sign-out clears the account\'s cache but keeps this device\'s settings', () async {
    await client.refresh();
    p.social.updateSound(false);
    p.rememberCity('SE', 'Stockholm');
    client.signedOut();
    expect(p.count, 0);
    expect(p.fromServer, isFalse);
    expect(p.social.sound, isFalse);
    expect(p.progressOf('SE').city, 'Stockholm');
    expect(p.store.getBool(PassportClient.importedKey), isTrue);
  });
}

class _FakeApi implements PassportApi {
  _FakeApi(this.current);

  PassportServerState current;
  List<PassportServerEvent> events = const [];
  APIException? importError;
  Map<String, Object?>? imported;
  int? ackedThrough;
  final calls = <String>[];
  final profiles = <Map<String, Object?>>[];

  @override
  Future<PassportServerState> state() async {
    calls.add('state');
    return current;
  }

  @override
  Future<List<PassportServerEvent>> unseenEvents() async {
    calls.add('events');
    return events;
  }

  @override
  Future<void> ack(int throughId) async {
    calls.add('ack');
    ackedThrough = throughId;
  }

  @override
  Future<PassportServerState?> profile(Map<String, Object?> fields) async {
    calls.add('profile');
    profiles.add(fields);
    return current;
  }

  @override
  Future<void> share() async => calls.add('share');

  @override
  Future<PassportServerState?> importV1(Map<String, Object?> body) async {
    calls.add('import');
    imported = body;
    if (importError != null) throw importError!;
    return current;
  }
}
