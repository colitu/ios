import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parts of Colitu Passport the app still computes itself since v2 (the
/// server evaluates the rules, see passport_client_test.dart): levels, the
/// reward format, the weekly rotation, the passport QR, friends and the
/// identity.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final noon = DateTime(2026, 10, 24, 12);
  late DateTime now;
  late ColituPassport p;

  setUp(() {
    now = noon;
    p = ColituPassport(store: PassportStore(), clock: () => now);
  });

  void stamp(String code, int pieces) {
    p.store
      ..setInt('t_$code', noon.millisecondsSinceEpoch)
      ..setInt('p_$code', pieces);
  }

  group('levels', () {
    test('12 pieces a level, then Diamond complete', () {
      for (final (pieces, level) in [(0, StampLevel.bronze), (12, StampLevel.silver), (24, StampLevel.gold), (36, StampLevel.diamond)]) {
        stamp('PL', pieces);
        expect(p.progressOf('PL').level, level, reason: '$pieces');
      }
      stamp('PL', 48);
      final progress = p.progressOf('PL');
      expect(progress.mastered, isTrue);
      expect(progress.levelPieces, 12);
      expect(progress.toNext, 0);
    });

    test('progress maths', () {
      const s = StampProgress(13, 0, null, 1);
      expect(s.level, StampLevel.silver);
      expect(s.levelPieces, 1);
      expect(s.toNext, 11);
      expect(StampProgress.empty.level, isNull);
    });
  });

  test('every reward kind survives the queue format', () {
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

    test('without a server answer: the rotation, nothing done', () {
      expect(p.weekly.goals(), PassportWeekly.goalsOf(noon));
      expect(p.weekly.goals().map(p.weekly.progress), [0, 0, 0]);
      expect(p.weekly.total, 0);
    });
  });

  group('passport QR', () {
    test('my link decodes back to my levels', () {
      stamp('SE', 13); // Silver with one piece
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

  group('settings and identity', () {
    test('defaults: sound and haptics on', () {
      expect(p.social.sound, isTrue);
      expect(p.social.haptics, isTrue);
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

    test('nickname, title and cover go to the account, the favourite stays here', () {
      final sent = <Map<String, Object?>>[];
      p.profileSink = sent.add;
      p.goals.updateNickname(' Ali ');
      p.goals.updateTitle('nordic_master');
      p.goals.updateTitle(null);
      p.goals.updateCover(CoverTheme.baltic);
      p.goals.updateFavorite('SE');
      expect(sent, [
        {'nickname': 'Ali'},
        {'title_id': 'nordic-master'},
        {'title_id': ''},
        {'cover_id': 'baltic'},
      ]);
    });
  });
}
