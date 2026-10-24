import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:colitu_vpn/colitu/passport/passport_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colitu Passport rules, the same cases as Android's: 5-minute unlock, the
/// 10th and 60th minute, the daily cap, tester accounts, levels, the reward
/// queue, the weekly rotation, the passport QR and the tunnel's minute log.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final noon = DateTime(2026, 10, 24, 12);
  late DateTime now;
  late ColituPassport p;

  ColituPassport fresh() => ColituPassport(store: PassportStore(), clock: () => now);

  setUp(() {
    now = noon;
    p = fresh();
  });

  int at(int minute, {DateTime? from}) => (from ?? noon).add(Duration(minutes: minute)).millisecondsSinceEpoch;

  /// [n] minutes in a row in [cc], starting after minute [start].
  List<StampEvent> run(String cc, int n, {int start = 0, DateTime? from}) => [
    for (var i = 1; i <= n; i++) ...p.tick(cc, at: at(start + i, from: from)),
  ];

  group('stamps', () {
    test('five minutes in a row unlock Bronze', () {
      expect(run('DE', 4), isEmpty);
      expect(p.progressOf('DE').unlocked, isFalse);
      expect(p.tick('DE', at: at(5)), [const StampEvent.unlocked('DE')]);
      expect(p.progressOf('DE').level, StampLevel.bronze);
      expect(p.count, 1);
    });

    test('a gap over four minutes or another country starts the run again', () {
      run('DE', 3);
      p.tick('DE', at: at(8)); // five minutes later: new run
      run('DE', 3, start: 8);
      expect(p.progressOf('DE').unlocked, isFalse);
      run('FR', 2, start: 11);
      expect(p.tick('DE', at: at(14)), isEmpty);
      expect(p.store.getInt('run_min'), 1);
    });

    test('a core restart or reconnect inside the session keeps the run', () {
      // Two minutes, then the tunnel restarts (iOS killed it at its memory
      // cap): the next line comes 3.5 minutes later, then three more.
      p.tick('SE', at: at(1));
      p.tick('SE', at: at(2));
      final back = at(2) + 210000;
      expect(p.tick('SE', at: back), isEmpty);
      expect(p.tick('SE', at: back + 60000), isEmpty);
      expect(p.tick('SE', at: back + 120000), [const StampEvent.unlocked('SE')]);
      expect(p.store.getInt('run_min'), 5);
    });

    test('memory restarts every few minutes still unlock and replay from the log', () {
      // XHTTP on 5.9.9: a restart every 3-5 minutes, each one costing a
      // minute or two without a line.
      final lines = <String>[];
      var t = at(0);
      for (var i = 0; i < 4; i++) {
        for (var m = 0; m < 2; m++) {
          t += 60000;
          lines.add('$t,NL');
        }
        t += 150000;
      }
      now = DateTime.fromMillisecondsSinceEpoch(t);
      expect(PassportTickLog.replay(p, lines.join('\n')), 8);
      expect(p.progressOf('NL').unlocked, isTrue);
      expect(p.progressOf('NL').minutes, 8);
    });

    test('UK is Great Britain; junk codes are ignored', () {
      run('uk', 5);
      expect(p.progressOf('GB').unlocked, isTrue);
      expect(p.tick('Germany'), isEmpty);
      expect(p.tick(null), isEmpty);
    });
  });

  group('pieces', () {
    test('the 10th and the 60th minute each add a piece', () {
      final events = run('SE', 60);
      final pieces = events.where((e) => e.kind == StampEventKind.piece).toList();
      expect(pieces, [const StampEvent.piece('SE', 1), const StampEvent.piece('SE', 2)]);
      expect(p.progressOf('SE').pieces, 2);
      expect(p.today, (60, 2));
    });

    test('at most two a day, across servers', () {
      run('SE', 40);
      run('DE', 200, start: 40);
      expect(p.today.$2, 2);
      expect(p.progressOf('SE').pieces + p.progressOf('DE').pieces, 2);
      // The next day counts again.
      final tomorrow = DateTime(2026, 10, 25, 9);
      run('DE', 10, from: tomorrow);
      expect(p.store.getString('day'), '2026-10-25');
      expect(p.progressOf('DE').pieces, 2);
    });

    test('the piece goes to the connected country, else to the last unlocked one', () {
      run('SE', 10);
      expect(p.progressOf('SE').pieces, 1);
      run('SE', 46, start: 10);
      // Minutes 57-60 in Japan: still locked at the 60th, so the piece goes to Sweden.
      run('JP', 4, start: 56);
      expect(p.today, (60, 2));
      expect(p.progressOf('JP').unlocked, isFalse);
      expect(p.progressOf('SE').pieces, 2);
    });

    test('a locked country with no stamp yet earns nothing', () {
      // Four-minute hops never unlock anything: no target for the piece.
      for (var i = 0; i < 12; i++) {
        p.tick(i.isEven ? 'DE' : 'FR', at: at(i + 1));
      }
      expect(p.progress, isEmpty);
      expect(p.today, (12, 0));
    });

    test('reconnects do not lift the daily cap', () {
      // 150 minutes with a reconnect gap after every five.
      var t = at(0);
      for (var i = 1; i <= 150; i++) {
        t += i % 5 == 0 ? 200000 : 60000;
        p.tick('PL', at: t);
      }
      expect(p.today, (150, 2));
      expect(p.progressOf('PL').pieces, 2);
    });

    test('tester accounts: a piece every 10 minutes without the cap', () {
      p.tester = true;
      run('NL', 120);
      expect(p.progressOf('NL').pieces, 12);
      expect(p.progressOf('NL').level, StampLevel.silver);
      expect(p.today.$2, 12);
    });
  });

  group('levels', () {
    test('12 pieces a level, then Diamond complete', () {
      p.tester = true;
      final events = run('PL', 480);
      expect(events.where((e) => e.kind == StampEventKind.levelUp).map((e) => e.level), [
        StampLevel.silver,
        StampLevel.gold,
        StampLevel.diamond,
      ]);
      expect(events.where((e) => e.kind == StampEventKind.mastered).map((e) => e.code), ['PL']);
      final progress = p.progressOf('PL');
      expect(progress.mastered, isTrue);
      expect(progress.levelPieces, 12);
      expect(progress.toNext, 0);
      // The 12th piece of a level reports 12, not 0.
      expect(events.where((e) => e.kind == StampEventKind.piece).elementAt(11), const StampEvent.piece('PL', 12));
    });

    test('progress maths', () {
      const s = StampProgress(13, 0, null, 1);
      expect(s.level, StampLevel.silver);
      expect(s.levelPieces, 1);
      expect(s.toNext, 11);
      expect(StampProgress.empty.level, isNull);
    });
  });

  group('queue', () {
    test('rewards wait in order and are taken once', () {
      run('SE', 10);
      expect(p.takePending(), [const StampEvent.unlocked('SE'), const StampEvent.piece('SE', 1)]);
      expect(p.takePending(), isEmpty);
    });

    test('every kind survives the queue format', () {
      const all = [
        StampEvent.unlocked('SE'),
        StampEvent.piece('SE', 7),
        StampEvent.levelUp('SE', StampLevel.gold),
        StampEvent.mastered('SE'),
        StampEvent.achieved('night'),
        StampEvent.collected('nordic'),
        StampEvent.chapter('2'),
        StampEvent.expedition('share'),
        StampEvent.special('companion'),
      ];
      for (final e in all) {
        expect(StampEvent.decode(e.encode()), e);
      }
      expect(StampEvent.decode('Z|SE'), isNull);
      expect(StampEvent.decode('L|SE|plastic'), isNull);
    });

    test('Companion stamp is queued once', () {
      p.social.markCompanion();
      p.social.markCompanion();
      expect(p.takePending(), [const StampEvent.special('companion')]);
      expect(p.social.companion, isTrue);
    });

    test('sets, chapters and achievements are found once', () {
      run('SE', 5);
      final first = p.goals.checkNew();
      expect(first, contains(const StampEvent.achieved('first')));
      expect(p.goals.checkNew(), isEmpty);
    });

    test('Chapter 02 opens with every Origin stamp and replays its early stamps', () {
      var minute = 0;
      run('NO', 5, start: minute);
      minute += 10;
      for (final s in ColituPassport.stamps) {
        run(s.code, 5, start: minute);
        minute += 10;
      }
      expect(p.chapter2Open, isTrue);
      final found = p.goals.checkNew();
      expect(found.take(2), [const StampEvent.chapter('2'), const StampEvent.unlocked('NO')]);
      expect(found, contains(const StampEvent.achieved('origin')));
    });
  });

  group('weekly', () {
    test('ISO weeks', () {
      expect(PassportWeekly.weekKeyOf(DateTime(2026, 1, 1)), '2026-W1');
      expect(PassportWeekly.weekKeyOf(DateTime(2027, 1, 1)), '2026-W53');
      expect(PassportWeekly.weekKeyOf(DateTime(2026, 10, 24)), '2026-W43');
    });

    test('three goals by a fixed rotation on the week number', () {
      const all = ExpeditionGoal.values;
      final n = 2026 * 53 + 43;
      expect(PassportWeekly.goalsOf(DateTime(2026, 10, 24)), [for (var i = 0; i < 3; i++) all[(n * 3 + i) % 6]]);
      expect(PassportWeekly.goalsOf(DateTime(2026, 10, 19)), PassportWeekly.goalsOf(DateTime(2026, 10, 25)));
      expect(PassportWeekly.goalsOf(DateTime(2026, 10, 26)), isNot(PassportWeekly.goalsOf(DateTime(2026, 10, 25))));
    });

    test('steps count only for this week\'s goals and are rewarded once', () {
      final goals = p.weekly.goals();
      for (final g in ExpeditionGoal.values) {
        for (var i = 0; i < g.target; i++) {
          p.weekly.bump(g);
        }
      }
      for (final g in ExpeditionGoal.values) {
        expect(p.weekly.progress(g), goals.contains(g) ? g.target : 0, reason: g.id);
      }
      expect(p.weekly.takeNewlyDone(), goals);
      expect(p.weekly.takeNewlyDone(), isEmpty);
      expect(p.weekly.total, 3);
      // A new week starts from zero.
      now = noon.add(const Duration(days: 7));
      expect(p.weekly.goals().map(p.weekly.progress), [0, 0, 0]);
    });
  });

  group('passport QR', () {
    test('my link decodes back to my levels', () {
      p.tester = true;
      run('SE', 130); // Silver with one piece
      p.goals.updateNickname('Ayşe|x');
      final link = p.social.myDuelLink();
      expect(link, startsWith('https://colitu.com/p#'));
      expect(link, isNot(contains('=')));
      final duel = PassportSocial.parseDuel(link)!;
      expect(duel.nick, 'Ayşex');
      expect(duel.collector, p.goals.collectorNo);
      expect(duel.levels['SE'], 2);
      expect(duel.levels['FI'], 0);
      expect(duel.count(ColituPassport.stamps), 1);
    });

    test('reads a link made by the Android app', () {
      final duel = PassportSocial.parseDuel('https://colitu.com/p#MXxBecWfZXw0ODI5MTN8bmlnaHR8NDMyMTAwMDAwMDUwMDAwMDAwMDE')!;
      expect(duel.nick, 'Ayşe');
      expect(duel.collector, '482913');
      expect(duel.title, 'night');
      expect([duel.levels['SE'], duel.levels['FI'], duel.levels['DE'], duel.levels['NL']], [4, 3, 2, 1]);
      expect(duel.levels['NO'], 5);
      expect(duel.levels['AU'], 1);
    });

    test('rejects other codes', () {
      expect(PassportSocial.parseDuel('https://colitu.com/r/ABCDEF'), isNull);
      expect(PassportSocial.parseDuel('https://colitu.com/p#!!!'), isNull);
      expect(PassportSocial.parseDuel('https://colitu.com/p#MnxhfGJ8Y3wwMDA'), isNull); // version 2
    });

    test('friends: one per collector number, never myself', () {
      final duel = PassportSocial.parseDuel('https://colitu.com/p#MXxBecWfZXw0ODI5MTN8bmlnaHR8NDMyMTAwMDAwMDUwMDAwMDAwMDE')!;
      p.social.addFriend(duel.toFriend(1));
      p.social.addFriend(duel.toFriend(2));
      expect(p.social.friends, hasLength(1));
      expect(p.social.friends.single.score, 4 + 3 + 2 + 1 + 5 + 1);
      p.social.addFriend(PassportFriend(nick: 'me', collector: p.goals.collectorNo, levels: '', addedAt: 3));
      expect(p.social.friends, hasLength(1));
      p.social.removeFriend('482913');
      expect(p.social.friends, isEmpty);
    });
  });

  group('tunnel minute log', () {
    test('parse keeps new lines in order, without duplicates or future times', () {
      final text = [
        '${at(3)},SE',
        '${at(1)},se',
        '${at(1) + 1000},SE', // the same minute written twice
        '${at(2)},XYZ',
        'junk',
        '${at(500)},SE', // in the future
        '${at(2)},UK',
      ].join('\n');
      final ticks = PassportTickLog.parse(text, after: at(0), now: at(10));
      expect(ticks.map((t) => (t.at, t.country)), [(at(1), 'SE'), (at(2), 'GB'), (at(3), 'SE')]);
      expect(PassportTickLog.parse(text, after: at(2), now: at(10)), hasLength(1));
    });

    test('replay applies the rules with the lines\' own times, once', () {
      now = noon.add(const Duration(hours: 3));
      final text = [for (var i = 1; i <= 70; i++) '${at(i)},FI'].join('\n');
      expect(PassportTickLog.replay(p, text), 70);
      expect(p.progressOf('FI').pieces, 2);
      expect(p.progressOf('FI').unlockedAt, at(5));
      expect(p.today, (70, 2));
      // The same file again: nothing new.
      expect(PassportTickLog.replay(p, text), 0);
      expect(p.today, (70, 2));
    });

    test('a night across midnight counts for both days', () {
      final late = DateTime(2026, 10, 24, 23, 30);
      now = DateTime(2026, 10, 25, 1);
      final text = [for (var i = 1; i <= 60; i++) '${at(i, from: late)},LV'].join('\n');
      PassportTickLog.replay(p, text);
      // 29 minutes on the 24th (piece at 10), 31 from midnight on the 25th (piece at 10).
      expect(p.progressOf('LV').pieces, 2);
      expect(p.today, (31, 1));
    });

    test('notification texts for the tunnel', () async {
      await ColituLoc.I.setLanguage('en', persist: false);
      final config = PassportSync.notifyConfig(p, 'DE');
      expect(config['on'], isTrue);
      expect(config['locked'], ['DE']);
      expect((config['countries'] as Map)['DE']['unlockTitle'], contains('Germany'));
      expect(config.containsKey('pieceTitle'), isFalse); // no stamp yet to take a piece
      run('DE', 5);
      final after = PassportSync.notifyConfig(p, 'DE');
      expect(after['locked'], isEmpty);
      expect(after['pieceTitle'], contains('Germany'));
    });
  });

  group('settings and counters', () {
    test('defaults: notifications, sound and haptics on, anonymous counters off', () {
      expect(p.notify, isTrue);
      expect(p.social.sound, isTrue);
      expect(p.social.haptics, isTrue);
      expect(p.social.metrics, isFalse);
      expect(p.social.metricsPayload(), isNull);
    });

    test('anonymous counters once a day, totals only, platform ios', () {
      run('SE', 10);
      p.social.updateMetrics(true);
      final body = p.social.metricsPayload()!;
      expect(body, {
        'v': 1,
        'platform': 'ios',
        'stamps': 1,
        'chapter': 1,
        'levels': [1, 0, 0, 0],
        'expeditions': 0,
        'pieces_today': 1,
        'opened_today': true,
      });
      p.social.metricsSent();
      expect(p.social.metricsPayload(), isNull);
      now = noon.add(const Duration(days: 1));
      expect(p.social.metricsPayload(), isNotNull);
    });

    test('nickname is trimmed and capped; covers follow the plan and sets', () {
      p.goals.updateNickname('  ${'x' * 30}  ');
      expect(p.goals.nickname, hasLength(20));
      expect(p.goals.activeCover(false), CoverTheme.classic);
      expect(p.goals.activeCover(true), CoverTheme.premium);
      p.goals.updateCover(CoverTheme.nordic);
      expect(p.goals.activeCover(true), CoverTheme.premium); // Nordic set not done
      expect(p.goals.collectorNo, matches(RegExp(r'^\d{6}$')));
      expect(p.goals.collectorNo, p.goals.collectorNo);
    });
  });
}
