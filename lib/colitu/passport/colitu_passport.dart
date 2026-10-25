import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';

// Colitu Passport model (Android colitu/data/ColituPassport.kt,
// PassportGoals.kt, PassportWeekly.kt, PassportSocial.kt). Since v2 the
// passport lives on the server, per account: the server counts the minutes
// from the nodes' traffic reports and evaluates every rule. The app keeps the
// last server state in [PassportStore] (see PassportServerState.applyTo) for
// offline display, plays the reveals of the server's events and sends
// cosmetic choices. Friends, the cities under the stamps and the sound and
// haptics switches stay on this device.

/// One passport stamp: the country it stands for and its printed number.
@immutable
class ColituStamp {
  const ColituStamp(this.code, this.number);

  final String code;
  final int number;

  @override
  bool operator ==(Object other) => other is ColituStamp && other.code == code && other.number == number;

  @override
  int get hashCode => Object.hash(code, number);
}

/// Stamp material; every level is one 12-piece puzzle.
enum StampLevel {
  bronze('bronze'),
  silver('silver'),
  gold('gold'),
  diamond('diamond');

  const StampLevel(this.key);

  final String key;
}

/// What the device knows about one stamp. Unlocked once [unlockedAt] is set.
@immutable
class StampProgress {
  const StampProgress(this.pieces, this.minutes, this.city, this.unlockedAt);

  static const pieceCount = 12;
  static const empty = StampProgress(0, 0, null, 0);

  final int pieces;
  final int minutes;
  final String? city;
  final int unlockedAt;

  bool get unlocked => unlockedAt > 0;

  StampLevel? get level => !unlocked
      ? null
      : StampLevel.values[math.min(pieces ~/ pieceCount, StampLevel.values.length - 1)];

  /// Diamond with its puzzle full: nothing left to collect.
  bool get mastered => pieces >= pieceCount * StampLevel.values.length;

  /// Filled pieces (0-12) of the current level's puzzle.
  int get levelPieces => mastered ? pieceCount : pieces % pieceCount;

  int get toNext => pieceCount - levelPieces;

  StampProgress copyWith({int? pieces}) => StampProgress(pieces ?? this.pieces, minutes, city, unlockedAt);
}

enum StampEventKind { unlocked, piece, levelUp, mastered, achieved, collected, chapter, expedition, special }

/// A reward waiting for the app to show it. [code] is the country, or the
/// id of the achievement / set / goal / special stamp, or the chapter number.
@immutable
class StampEvent {
  const StampEvent(this.kind, this.code, {this.levelPieces = 0, this.level});

  const StampEvent.unlocked(String code) : this(StampEventKind.unlocked, code);
  const StampEvent.piece(String code, int levelPieces) : this(StampEventKind.piece, code, levelPieces: levelPieces);
  const StampEvent.levelUp(String code, StampLevel level) : this(StampEventKind.levelUp, code, level: level);
  const StampEvent.mastered(String code) : this(StampEventKind.mastered, code);
  const StampEvent.achieved(String id) : this(StampEventKind.achieved, id);
  const StampEvent.collected(String id) : this(StampEventKind.collected, id);
  const StampEvent.chapter(String number) : this(StampEventKind.chapter, number);
  const StampEvent.expedition(String id) : this(StampEventKind.expedition, id);
  const StampEvent.special(String id) : this(StampEventKind.special, id);

  final StampEventKind kind;
  final String code;
  final int levelPieces;
  final StampLevel? level;

  /// Queue format, the same as Android: "U|SE", "P|SE|3", "L|SE|gold" …
  String encode() => switch (kind) {
    StampEventKind.unlocked => 'U|$code',
    StampEventKind.piece => 'P|$code|$levelPieces',
    StampEventKind.levelUp => 'L|$code|${level!.key}',
    StampEventKind.mastered => 'M|$code',
    StampEventKind.achieved => 'A|$code',
    StampEventKind.collected => 'C|$code',
    StampEventKind.chapter => 'H|$code',
    StampEventKind.expedition => 'X|$code',
    StampEventKind.special => 'S|$code',
  };

  static StampEvent? decode(String s) {
    final p = s.split('|');
    if (p.length < 2) return null;
    final code = p[1];
    String? third() => p.length > 2 ? p[2] : null;
    return switch (p[0]) {
      'U' => StampEvent.unlocked(code),
      'P' => StampEvent.piece(code, int.tryParse(third() ?? '') ?? 0),
      'L' => StampLevel.values.where((l) => l.key == third()).map((l) => StampEvent.levelUp(code, l)).firstOrNull,
      'M' => StampEvent.mastered(code),
      'A' => StampEvent.achieved(code),
      'C' => StampEvent.collected(code),
      'H' => StampEvent.chapter(code),
      'X' => StampEvent.expedition(code),
      'S' => StampEvent.special(code),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is StampEvent &&
      other.kind == kind &&
      other.code == code &&
      other.levelPieces == levelPieces &&
      other.level == level;

  @override
  int get hashCode => Object.hash(kind, code, levelPieces, level);

  @override
  String toString() => encode();
}

/// Achievements: each gives a title the user can show on the passport.
/// Secret ones show as "???" until earned. Titles stay in English (a badge).
enum PassportAchievement {
  first('first', 'First Connection', false),
  globetrotter('globe', 'Globetrotter', false),
  origin('origin', 'Origin Collector', false),
  nordicMaster('nordic_master', 'Nordic Master', false),
  night('night', 'Night Explorer', true),
  early('early', 'Early Bird', true),
  longHaul('longhaul', 'Long Haul', true),
  diamond('diamond', 'Diamond Collector', true),
  pathfinder('pathfinder', 'Pathfinder', false),
  legacyGold('legacy_gold', 'Golden Passport', false),
  legacyDiamond('legacy_diamond', 'Diamond Passport', false);

  const PassportAchievement(this.id, this.title, this.secret);

  final String id;
  final String title;
  final bool secret;
}

/// Passport cover looks. Classic for everyone, Premium with the plan, the
/// rest from sets.
enum CoverTheme {
  classic('classic'),
  premium('premium'),
  nordic('nordic'),
  baltic('baltic'),
  atlantic('atlantic'),
  pacific('pacific');

  const CoverTheme(this.key);

  final String key;
}

/// Collection sets. Their countries may belong to a later chapter: those
/// stamps are recorded already, so a set can be finished before its chapter
/// opens. [cover] is the cover theme the set gives, if any.
enum PassportCollection {
  nordic('nordic', 'Nordic', ['SE', 'FI', 'NO'], false, CoverTheme.nordic),
  baltic('baltic', 'Baltic', ['LV', 'EE', 'LT'], false, CoverTheme.baltic),
  atlantic('atlantic', 'Across the Atlantic', ['US', 'GB', 'CA'], false, CoverTheme.atlantic),
  heart('heart', 'Heart of Europe', ['DE', 'FR', 'NL', 'PL', 'CH'], false, null),
  pacific('pacific', 'Pacific Rim', ['JP', 'SG', 'HK', 'AU'], false, CoverTheme.pacific),
  goldRush('gold_rush', 'Gold Rush', [], true, null);

  const PassportCollection(this.id, this.title, this.codes, this.secret, this.cover);

  final String id;
  final String title;
  final List<String> codes;
  final bool secret;
  final CoverTheme? cover;
}

/// One kind of weekly expedition and how many steps it takes.
enum ExpeditionGoal {
  newCountry('new_country', 1),
  share('share', 1),
  customize('customize', 1),
  days10('days10', 3),
  setStamp('set_stamp', 1),
  pieces('pieces', 4);

  const ExpeditionGoal(this.id, this.target);

  final String id;
  final int target;
}

/// A friend's passport as read from their QR (no account data, only what
/// their share card shows).
@immutable
class PassportFriend {
  const PassportFriend({
    required this.nick,
    required this.collector,
    this.title,
    required this.levels,
    required this.addedAt,
  });

  final String nick;
  final String collector;
  final String? title;

  /// One digit per stamp in [ColituPassport.allStamps] order: 0 locked,
  /// 1-4 Bronze..Diamond, 5 Diamond complete.
  final String levels;
  final int addedAt;

  int level(String code) {
    final i = ColituPassport.allStamps.indexWhere((s) => s.code == code);
    if (i < 0 || i >= levels.length) return 0;
    return int.tryParse(levels[i]) ?? 0;
  }

  int count(List<ColituStamp> chapter) => chapter.where((s) => level(s.code) > 0).length;

  /// Sum of levels: the tie-breaker of the friends ranking.
  int get score => levels.split('').fold(0, (sum, c) => sum + (int.tryParse(c) ?? 0));

  Map<String, Object> toJson() => {
    'nick': nick,
    'collector': collector,
    'title': ?title,
    'levels': levels,
    'added': addedAt,
  };
}

/// What a passport QR carries: no account data, only what the share card shows.
@immutable
class DuelPassport {
  const DuelPassport(this.nick, this.collector, this.title, this.levels);

  final String nick;
  final String collector;
  final String? title;

  /// Level code per stamp: 0 locked, 1-4 Bronze..Diamond, 5 Diamond complete.
  final Map<String, int> levels;

  int count(List<ColituStamp> chapter) => chapter.where((s) => (levels[s.code] ?? 0) > 0).length;

  PassportFriend toFriend(int now) => PassportFriend(
    nick: nick,
    collector: collector,
    title: title,
    levels: ColituPassport.allStamps.map((s) => '${levels[s.code] ?? 0}').join(),
    addedAt: now,
  );

  static DuelPassport fromFriend(PassportFriend f) => DuelPassport(
    f.nick,
    f.collector,
    f.title,
    {for (final s in ColituPassport.allStamps) s.code: f.level(s.code)},
  );
}

/// Colitu Passport as the server last reported it (see PassportClient).
///
/// Rules (evaluated on the server): five minutes in a row in a country
/// unlock its Bronze stamp. Every day the 10th and the 60th minute of use
/// each add one puzzle piece to the stamp of the country of that minute, at
/// most two a day. Tester accounts get a piece every ten minutes without the
/// daily cap. The constants below only describe the rules on screen.
class ColituPassport extends ChangeNotifier {
  ColituPassport({PassportStore? store, DateTime Function()? clock, math.Random? random})
    : store = store ?? PassportStore(),
      _clock = clock ?? ColituClock.now,
      _random = random ?? math.Random.secure();

  /// The app's passport; replaced once the saved one is loaded.
  static ColituPassport I = ColituPassport();

  final PassportStore store;
  final DateTime Function() _clock;
  final math.Random _random;

  DateTime now() => _clock();

  static const unlockMinutes = 5;
  static const pieceMinutes = [10, 60];
  static const testerEvery = 10;


  static List<ColituStamp> _chapter(List<String> codes, int first) => [
    for (var i = 0; i < codes.length; i++) ColituStamp(codes[i], first + i),
  ];

  /// Chapter 01 — Origin. Other countries are recorded too, for the next chapter.
  static final stamps = _chapter(['SE', 'FI', 'DE', 'NL', 'GB', 'PL', 'LV', 'FR', 'US', 'JP'], 1);

  /// Chapter 02 — Horizons; opens once Chapter 01 is complete. No Russia or
  /// Kazakhstan (owner decision).
  static final chapter2 = _chapter(['NO', 'EE', 'LT', 'CH', 'CA', 'TR', 'SG', 'HK', 'BR', 'AU'], 11);

  static final allStamps = [...stamps, ...chapter2];

  static ColituStamp? stampOf(String code) => allStamps.where((s) => s.code == code).firstOrNull;

  static String? normalize(String? code) {
    var c = code?.trim().toUpperCase();
    if (c == null) return null;
    if (c == 'UK') c = 'GB';
    return c.length == 2 ? c : null;
  }

  static ColituStamp? stampFor(String? code) {
    final c = normalize(code);
    return c == null ? null : stampOf(c);
  }

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int epochDay(DateTime d) => DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  late final goals = PassportGoals._(this);
  late final weekly = PassportWeekly._(this);
  late final social = PassportSocial._(this);

  /// Sends a changed nickname, title or cover to the account (PassportClient).
  void Function(Map<String, Object?> fields)? profileSink;

  // ── State ───────────────────────────────────────────────────────────────

  StampProgress _read(String code) => StampProgress(
    store.getInt('p_$code'),
    store.getInt('m_$code'),
    store.getString('city_$code'),
    store.getInt('t_$code'),
  );

  /// Country code → progress, unlocked stamps only.
  Map<String, StampProgress> get progress => {
    for (final s in allStamps)
      if (_read(s.code).unlocked) s.code: _read(s.code),
  };

  StampProgress progressOf(String code) => _read(code);

  /// The server reported today's minutes (for this local day).
  bool get todayKnown => fromServer && store.getString('day') == dayKey(now());

  /// Minutes of use today and pieces already earned today; (0, 0) until the
  /// server reported this day.
  (int, int) get today {
    if (!todayKnown) return (0, 0);
    return (store.getInt('day_min'), store.getInt('day_pieces'));
  }

  /// Chapter 01 stamps collected (the passport's main count).
  int get count => stamps.where((s) => _read(s.code).unlocked).length;

  bool get complete => count == stamps.length;

  int countIn(List<ColituStamp> chapter) => chapter.where((s) => _read(s.code).unlocked).length;

  /// Chapter 02 is open: every Chapter 01 stamp collected.
  bool get chapter2Open => stamps.every((s) => _read(s.code).unlocked);

  /// Tester account (the server's flag): a piece every ten minutes.
  bool get tester => store.getBool('tester');

  set tester(bool value) => store.setBool('tester', value);

  /// The server has answered at least once: its lists are the truth.
  bool get fromServer => store.getInt('srv_at') > 0;

  /// Every country with a stamp record, this chapter or not.
  bool unlockedAnywhere(String code) => store.getInt('t_$code') > 0;

  /// Re-reads everything; widgets listening rebuild.
  void reload() {
    weekly.refresh();
    notifyListeners();
  }

  /// The app remembers the city shown under a stamp.
  void rememberCity(String? countryCode, String? city) {
    final code = normalize(countryCode);
    if (code == null || city == null || city.trim().isEmpty) return;
    store.setString('city_$code', city);
  }

  // ── Demo (tests and screenshots) ────────────────────────────────────────

  /// A demo passport with every level, or an empty one.
  @visibleForTesting
  void debugCycle() {
    final t = now().millisecondsSinceEpoch;
    final keepTester = tester;
    final collector = store.getString('collector_no');
    if (count > 0) {
      store.clear();
    } else {
      const set = {
        'SE': 48, 'FI': 40, 'DE': 28, 'NL': 37, 'GB': 15, 'PL': 12, 'LV': 11, 'FR': 2, 'US': 0,
        // Next chapter's countries: Nordic complete, Baltic 2 of 3.
        'NO': 3, 'EE': 1,
      };
      store.setInt('a_night', t);
      set.forEach((code, pieces) {
        store.setInt('t_$code', t);
        store.setInt('p_$code', pieces);
        store.setInt('m_$code', 30 + pieces * 40);
      });
    }
    tester = keepTester;
    if (collector != null) store.setString('collector_no', collector);
    reload();
  }

  /// Six random digits made on this device, not tied to the account.
  String newCollectorNo() => (100000 + _random.nextInt(900000)).toString();
}

/// Achievements, collections and the passport identity (nickname, collector
/// number, favourite stamp, title, cover). The server's lists once it has
/// answered; the favourite stamp stays on this device.
class PassportGoals {
  PassportGoals._(this._p);

  final ColituPassport _p;

  PassportStore get _store => _p.store;

  static const goldRushCount = 3;
  static const diamondCount = 3;

  String get nickname => _store.getString('nick') ?? '';

  String? get favorite => _store.getString('favorite');

  String? get title => _store.getString('title');

  CoverTheme? get cover {
    final key = _store.getString('cover');
    return CoverTheme.values.where((c) => c.key == key).firstOrNull;
  }

  String get collectorNo {
    final saved = _store.getString('collector_no');
    if (saved != null) return saved;
    final made = _p.newCollectorNo();
    _store.setString('collector_no', made);
    return made;
  }

  void updateNickname(String value) {
    final v = value.trim();
    final nick = v.isEmpty ? null : (v.length > 20 ? v.substring(0, 20) : v);
    _save('nick', nick);
    _p.profileSink?.call({'nickname': nick ?? ''});
  }

  void updateFavorite(String? code) => _save('favorite', code);

  void updateTitle(String? id) {
    _save('title', id);
    _p.profileSink?.call({'title_id': id == null ? '' : id.replaceAll('_', '-')});
  }

  void updateCover(CoverTheme? theme) {
    _save('cover', theme?.key);
    _p.profileSink?.call({'cover_id': theme?.key ?? ''});
  }

  void _save(String key, String? value) {
    if (value == null) {
      _store.remove(key);
    } else {
      _store.setString(key, value);
    }
    _p.reload();
  }

  /// Every country with a record: this chapter, the sets and whatever the tunnel saw.
  List<String> _allCodes() => {
    ...ColituPassport.stamps.map((s) => s.code),
    ...PassportCollection.values.expand((c) => c.codes),
    ...(_store.getString('codes') ?? '').split(','),
  }.where((c) => c.length == 2).toList();

  int _levelIndex(String code) => _p.progressOf(code).level?.index ?? -1;

  /// Stamps of [chapter] at [level] or higher (Chapter 03 — Legacy).
  int legacy(StampLevel level, List<ColituStamp> chapter) =>
      chapter.where((s) => _levelIndex(s.code) >= level.index).length;

  /// Chapter 03 opens with Chapter 02 complete.
  bool get chapter3Open => _p.countIn(ColituPassport.chapter2) == ColituPassport.chapter2.length;

  /// Ring around the account avatar: Diamond with Diamond Collector, gold
  /// with any Gold stamp.
  StampLevel? avatarFrame() {
    if (achieved(PassportAchievement.diamond)) return StampLevel.diamond;
    if (_countAtLeast(StampLevel.gold) > 0) return StampLevel.gold;
    return null;
  }

  int _countAtLeast(StampLevel level) => _allCodes().where((c) => _levelIndex(c) >= level.index).length;

  /// A list the server sent (local ids), or null before its first answer.
  Set<String>? _serverList(String key) {
    if (!_p.fromServer) return null;
    return (_store.getString(key) ?? '').split(',').where((id) => id.isNotEmpty).toSet();
  }

  bool achieved(PassportAchievement a) => _serverList('srv_ach')?.contains(a.id) ?? _achievedHere(a);

  /// Before the server answered: what this device recorded (v1).
  bool _achievedHere(PassportAchievement a) => switch (a) {
    PassportAchievement.first => _allCodes().any(_p.unlockedAnywhere),
    PassportAchievement.origin => ColituPassport.stamps.every((s) => _p.unlockedAnywhere(s.code)),
    PassportAchievement.nordicMaster => PassportCollection.nordic.codes.every((c) => _levelIndex(c) >= StampLevel.gold.index),
    PassportAchievement.diamond => _countAtLeast(StampLevel.diamond) >= diamondCount,
    PassportAchievement.pathfinder => _p.weekly.total >= PassportWeekly.pathfinderAt,
    PassportAchievement.legacyGold => legacy(StampLevel.gold, ColituPassport.stamps) >= ColituPassport.stamps.length,
    PassportAchievement.legacyDiamond => legacy(StampLevel.diamond, ColituPassport.stamps) >= ColituPassport.stamps.length,
    _ => _store.getInt('a_${a.id}') > 0,
  };

  /// Stamps of the set already collected, and how many it needs.
  (int, int) progress(PassportCollection c) {
    if (c == PassportCollection.goldRush) {
      return (math.min(_countAtLeast(StampLevel.gold), goldRushCount), goldRushCount);
    }
    return (c.codes.where(_p.unlockedAnywhere).length, c.codes.length);
  }

  bool completed(PassportCollection c) {
    final server = _serverList('srv_col');
    if (server != null) return server.contains(c.id);
    final (have, need) = progress(c);
    return have >= need;
  }

  /// When the set or achievement was first seen complete (0 when not yet).
  int earnedAt(String key) => _store.getInt('seen_$key');

  /// Covers this user may pick.
  List<CoverTheme> covers(bool premium) => [
    CoverTheme.classic,
    if (premium) CoverTheme.premium,
    for (final c in PassportCollection.values)
      if (c.cover != null && completed(c)) c.cover!,
  ];

  /// The cover shown: the chosen one while still allowed, else Premium or Classic.
  CoverTheme activeCover(bool premium) {
    final chosen = cover;
    if (chosen != null && covers(premium).contains(chosen)) return chosen;
    return premium ? CoverTheme.premium : CoverTheme.classic;
  }

  String? titleOf(String? id) {
    final a = PassportAchievement.values.where((a) => a.id == id).firstOrNull;
    return a != null && achieved(a) ? a.title : null;
  }

}

/// Weekly expeditions: three small goals a week, picked by a fixed rotation
/// on the ISO week number (no randomness). The server counts the progress
/// (the app reports shares); missing a week costs nothing. The rewards are
/// visa stamps and, after five, the Pathfinder title.
class PassportWeekly {
  PassportWeekly._(this._p);

  final ColituPassport _p;

  PassportStore get _store => _p.store;

  static const pathfinderAt = 5;

  /// Changes when the stored week changes, so the weekly card redraws.
  var version = 0;
  var _signature = '';

  void refresh() {
    final now =
        '${_store.getString('wk_key')}|${_store.getString('wk_goals')}|${ExpeditionGoal.values.map(progress).join(',')}|$total';
    if (now != _signature) {
      _signature = now;
      version++;
    }
  }

  /// ISO week-based year and week number of [date].
  static (int, int) isoWeek(DateTime date) {
    final d = DateTime.utc(date.year, date.month, date.day);
    // Thursday of this week decides the year.
    final thursday = d.add(Duration(days: 4 - d.weekday));
    final jan1 = DateTime.utc(thursday.year, 1, 1);
    final week = (thursday.difference(jan1).inDays ~/ 7) + 1;
    return (thursday.year, week);
  }

  static String weekKeyOf(DateTime date) {
    final (year, week) = isoWeek(date);
    return '$year-W$week';
  }

  String weekKey([DateTime? date]) => weekKeyOf(date ?? _p.now());

  /// The rotation of the week of [date] (the server uses the same one).
  static List<ExpeditionGoal> goalsOf(DateTime date) {
    final (year, week) = isoWeek(date);
    final n = year * 53 + week;
    const all = ExpeditionGoal.values;
    return [for (var i = 0; i < 3; i++) all[(n * 3 + i) % all.length]];
  }

  /// The stored week ("2026-W43" or "2026-W5") is this week.
  bool get _current {
    final m = RegExp(r'^(\d{4})-W(\d{1,2})$').firstMatch(_store.getString('wk_key') ?? '');
    return m != null && (int.parse(m[1]!), int.parse(m[2]!)) == isoWeek(_p.now());
  }

  /// This week's three goals: the server's, else the rotation.
  List<ExpeditionGoal> goals([DateTime? date]) {
    if (date == null && _current) {
      final ids = (_store.getString('wk_goals') ?? '').split(',');
      final list = [for (final id in ids) ...ExpeditionGoal.values.where((g) => g.id == id)];
      if (list.isNotEmpty) return list;
    }
    return goalsOf(date ?? _p.now());
  }

  int progress(ExpeditionGoal goal) => _current ? _store.getInt('wk_${goal.id}') : 0;

  bool done(ExpeditionGoal goal) =>
      progress(goal) >= goal.target || (_current && _store.getBool('wk_done_${goal.id}'));

  /// Expeditions finished over all weeks.
  int get total => _store.getInt('expeditions_done');
}

/// Friends, the Companion stamp and the passport's own settings. Friends and
/// settings stay on this device; the Companion stamp comes from the server.
class PassportSocial {
  PassportSocial._(this._p);

  final ColituPassport _p;

  PassportStore get _store => _p.store;

  static const companionId = 'companion';
  static const duelPrefix = 'https://colitu.com/p#';

  bool get showRanking => _store.getBool('friends_ranking', true);
  bool get sound => _store.getBool('sound', true);
  bool get haptics => _store.getBool('haptics', true);

  void updateRanking(bool on) => _flag('friends_ranking', on);
  void updateSound(bool on) => _flag('sound', on);
  void updateHaptics(bool on) => _flag('haptics', on);

  void _flag(String key, bool on) {
    _store.setBool(key, on);
    _p.reload();
  }

  // ── Friends ─────────────────────────────────────────────────────────────

  List<PassportFriend> get friends {
    try {
      final raw = _store.getString('friends');
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map && e['collector'] is String)
            PassportFriend(
              nick: e['nick'] is String ? e['nick'] as String : '',
              collector: e['collector'] as String,
              title: e['title'] is String ? e['title'] as String : null,
              levels: e['levels'] is String ? e['levels'] as String : '',
              addedAt: e['added'] is int ? e['added'] as int : 0,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _saveFriends(List<PassportFriend> list) {
    _store.setString('friends', jsonEncode([for (final f in list) f.toJson()]));
    _p.reload();
  }

  /// Adds or refreshes a friend scanned from a passport QR (one per collector number).
  void addFriend(PassportFriend friend) {
    if (friend.collector == _p.goals.collectorNo) return;
    final list = [...friends.where((f) => f.collector != friend.collector), friend]
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _saveFriends(list);
  }

  void removeFriend(String collector) => _saveFriends(friends.where((f) => f.collector != collector).toList());

  // ── Passport QR ─────────────────────────────────────────────────────────

  /// Level code of one of my stamps: 0 locked, 1-4 Bronze..Diamond, 5 Diamond complete.
  int myLevel(String code) {
    final p = _p.progressOf(code);
    if (!p.unlocked) return 0;
    if (p.mastered) return 5;
    return (p.level?.index ?? 0) + 1;
  }

  /// `https://colitu.com/p#<base64url of "1|nick|collector|title|levels">`,
  /// the same format as Android.
  String myDuelLink() {
    final levels = ColituPassport.allStamps.map((s) => '${myLevel(s.code)}').join();
    final raw = ['1', _p.goals.nickname.replaceAll('|', ''), _p.goals.collectorNo, _p.goals.title ?? '', levels].join('|');
    return duelPrefix + base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
  }

  static DuelPassport? parseDuel(String text) {
    try {
      if (!text.startsWith(duelPrefix)) return null;
      var body = text.substring(duelPrefix.length).trim();
      body = body.padRight((body.length + 3) ~/ 4 * 4, '=');
      final raw = utf8.decode(base64Url.decode(body));
      final p = raw.split('|');
      if (p.length < 5 || p[0] != '1') return null;
      final digits = p[4];
      final levels = <String, int>{
        for (var i = 0; i < ColituPassport.allStamps.length; i++)
          ColituPassport.allStamps[i].code: i < digits.length ? (int.tryParse(digits[i]) ?? 0) : 0,
      };
      return DuelPassport(p[1], p[2], p[3].isEmpty ? null : p[3], levels);
    } catch (_) {
      return null;
    }
  }

  // ── Companion stamp ─────────────────────────────────────────────────────

  bool get companion => _store.getInt('special_$companionId') > 0;

  int companionAt() => _store.getInt('special_$companionId');

  /// Whether the first-visit intro has been shown.
  bool get introSeen => _store.getBool('intro_seen');

  set introSeen(bool value) => _store.setBool('intro_seen', value);
}
