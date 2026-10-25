import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';

// Colitu Passport v2: the passport lives on the server, per account
// (colitu-panel docs/passport-server.md). The server counts the minutes from
// the nodes' traffic reports; this app only shows the state, plays the
// reveals of the server's events, sends cosmetic choices (nickname, title,
// cover, time zone), reports shares and imports the v1 progress of this
// device once.

/// Server ids use hyphens ("nordic-master"), the app's enums underscores.
String _localId(String id) => id.replaceAll('-', '_');
String _serverId(String id) => id.replaceAll('_', '-');

int _ms(Object? iso) => iso is String ? (DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? 0) : 0;

int _int(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

String? _text(Object? v) => v is String && v.isNotEmpty ? v : null;

Map<String, dynamic> _data(Object? root) {
  if (root is! Map) return const {};
  final data = root['data'] is Map ? root['data'] as Map : root;
  return data.cast<String, dynamic>();
}

/// One stamp of the server state.
@immutable
class PassportServerStamp {
  const PassportServerStamp(this.country, this.pieces, this.unlockedAt);

  final String country;
  final int pieces;
  final int unlockedAt;
}

/// One goal of the server's weekly expedition.
@immutable
class PassportServerGoal {
  const PassportServerGoal(this.id, this.target, this.progress, this.done);

  final String id;
  final int target;
  final int progress;
  final bool done;
}

/// `GET /client/passport`.
@immutable
class PassportServerState {
  const PassportServerState({
    this.collectorNo,
    this.nickname,
    this.titleId,
    this.coverId,
    this.tester = false,
    this.companion = false,
    this.day,
    this.dayMinutes = 0,
    this.dayPieces = 0,
    this.runCountry,
    this.runMinutes = 0,
    this.stamps = const [],
    this.achievements = const {},
    this.collections = const {},
    this.week,
    this.goals = const [],
    this.expeditionsDone = 0,
    this.unseenEvents = 0,
    this.updatedAt = 0,
  });

  final String? collectorNo;
  final String? nickname;

  /// Local ids (underscores).
  final String? titleId;
  final String? coverId;
  final bool tester;
  final bool companion;
  final String? day;
  final int dayMinutes;
  final int dayPieces;
  final String? runCountry;
  final int runMinutes;
  final List<PassportServerStamp> stamps;

  /// Local id → earned at (epoch ms).
  final Map<String, int> achievements;
  final Map<String, int> collections;
  final String? week;
  final List<PassportServerGoal> goals;
  final int expeditionsDone;
  final int unseenEvents;
  final int updatedAt;

  /// From the response root or the data object; null for anything else.
  static PassportServerState? parse(Object? root) {
    final d = _data(root);
    if (d.isEmpty) return null;
    final today = d['today'] is Map ? (d['today'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final run = d['run'] is Map ? (d['run'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final weekly = d['weekly'] is Map ? (d['weekly'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    Map<String, int> earned(Object? list) => {
      if (list is List)
        for (final e in list)
          if (e is Map && _text(e['id']) != null) _localId(e['id'] as String): _ms(e['earned_at']),
    };
    final title = _text(d['title_id']);
    return PassportServerState(
      collectorNo: _text(d['collector_no']),
      nickname: _text(d['nickname']),
      titleId: title == null ? null : _localId(title),
      coverId: _text(d['cover_id']),
      tester: d['tester'] == true,
      companion: d['companion'] == true,
      day: _text(today['day']),
      dayMinutes: _int(today['minutes']),
      dayPieces: _int(today['pieces']),
      runCountry: ColituPassport.normalize(_text(run['country'])),
      runMinutes: _int(run['minutes']),
      stamps: [
        if (d['stamps'] is List)
          for (final s in d['stamps'] as List)
            if (s is Map && ColituPassport.normalize(_text(s['country'])) != null)
              PassportServerStamp(
                ColituPassport.normalize(s['country'] as String)!,
                _int(s['pieces']).clamp(0, StampProgress.pieceCount * StampLevel.values.length),
                _ms(s['unlocked_at']),
              ),
      ],
      achievements: earned(d['achievements']),
      collections: earned(d['collections']),
      week: _text(weekly['week']),
      goals: [
        if (weekly['goals'] is List)
          for (final g in weekly['goals'] as List)
            if (g is Map && _text(g['id']) != null)
              PassportServerGoal(g['id'] as String, _int(g['target'], 1), _int(g['progress']), g['done'] == true),
      ],
      expeditionsDone: _int(d['expeditions_done']),
      unseenEvents: _int(d['unseen_events']),
      updatedAt: _ms(d['updated_at']),
    );
  }

  /// Writes this state into the passport's store, which then is a cache of
  /// the account's passport (shown offline as well).
  void applyTo(ColituPassport passport) {
    final store = passport.store;
    final codes = {for (final s in stamps) s.country};
    for (final key in store.snapshot().keys) {
      if (key.length == 4 && (key.startsWith('t_') || key.startsWith('p_')) && !codes.contains(key.substring(2))) {
        store.remove(key);
      }
    }
    for (final s in stamps) {
      store.setInt('t_${s.country}', s.unlockedAt > 0 ? s.unlockedAt : 1);
      store.setInt('p_${s.country}', s.pieces);
    }
    void text(String key, String? value) => value == null ? store.remove(key) : store.setString(key, value);
    if (collectorNo != null) store.setString('collector_no', collectorNo!);
    text('nick', nickname);
    text('title', titleId);
    text('cover', coverId);
    passport.tester = tester;
    if (!companion) {
      store.remove('special_${PassportSocial.companionId}');
    } else if (!passport.social.companion) {
      store.setInt('special_${PassportSocial.companionId}', passport.now().millisecondsSinceEpoch);
    }
    if (day != null) {
      store.setString('day', day!);
      store.setInt('day_min', dayMinutes);
      store.setInt('day_pieces', dayPieces);
    } else {
      // No day in the answer: nothing about today is shown.
      store.remove('day');
      store.remove('day_min');
      store.remove('day_pieces');
    }
    if (runCountry != null) {
      store.setString('run_cc', runCountry!);
      store.setInt('run_min', runMinutes);
    } else {
      store.remove('run_cc');
      store.remove('run_min');
    }
    void earned(String listKey, String prefix, Map<String, int> ids) {
      store.setString(listKey, ids.keys.join(','));
      ids.forEach((id, at) => store.setInt('seen_$prefix$id', at > 0 ? at : 1));
    }

    earned('srv_ach', 'a_', achievements);
    earned('srv_col', 'c_', collections);
    for (final g in ExpeditionGoal.values) {
      store.remove('wk_${g.id}');
      store.remove('wk_done_${g.id}');
    }
    text('wk_key', week);
    store.setString('wk_goals', goals.map((g) => g.id).join(','));
    for (final g in goals) {
      store.setInt('wk_${g.id}', g.progress);
      store.setBool('wk_done_${g.id}', g.done);
    }
    store.setInt('expeditions_done', expeditionsDone);
    store.setInt('srv_at', updatedAt > 0 ? updatedAt : passport.now().millisecondsSinceEpoch);
  }
}

/// One event of `GET /client/passport/events?unseen=1`.
@immutable
class PassportServerEvent {
  const PassportServerEvent(this.id, this.kind, this.payload);

  final int id;
  final String kind;
  final Map<String, dynamic> payload;

  /// An admin took something away (or reset the passport): no animation,
  /// one short neutral notice per batch. The state already shows it.
  static const revokeKinds = {
    'stamp_revoked',
    'achievement_revoked',
    'collection_revoked',
    'chapter_closed',
    'companion_revoked',
    'passport_reset',
  };

  bool get isRevoke => revokeKinds.contains(kind);

  static List<PassportServerEvent> parseList(Object? root) {
    final list = root is Map ? root['data'] : root;
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map && e['id'] is num && e['kind'] is String)
          PassportServerEvent(
            (e['id'] as num).toInt(),
            e['kind'] as String,
            e['payload'] is Map ? (e['payload'] as Map).cast<String, dynamic>() : const {},
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  /// The reveal this event plays, read against the state already applied;
  /// null for kinds or ids this app version does not know (acked all the same).
  StampEvent? toReveal(ColituPassport passport) {
    final country = ColituPassport.normalize(_text(payload['country']));
    final id = _text(payload['id']) ?? _text(payload['goal_id']);
    final local = id == null ? null : _localId(id);
    switch (kind) {
      case 'stamp_unlocked':
        return country == null ? null : StampEvent.unlocked(country);
      case 'piece':
        if (country == null) return null;
        var pieces = payload['level_pieces'] is num ? (payload['level_pieces'] as num).toInt() : null;
        if (pieces == null) {
          final total = payload['pieces'] is num ? (payload['pieces'] as num).toInt() : passport.progressOf(country).pieces;
          final progress = StampProgress(total, 0, null, 1);
          pieces = progress.levelPieces == 0 && total > 0 ? StampProgress.pieceCount : progress.levelPieces;
        }
        return StampEvent.piece(country, pieces.clamp(1, StampProgress.pieceCount));
      case 'level_up':
        if (country == null) return null;
        final level =
            StampLevel.values.where((l) => l.key == _text(payload['level'])).firstOrNull ??
            passport.progressOf(country).level;
        return level == null ? null : StampEvent.levelUp(country, level);
      case 'mastered':
        return country == null ? null : StampEvent.mastered(country);
      case 'achievement':
        return PassportAchievement.values.any((a) => a.id == local) ? StampEvent.achieved(local!) : null;
      case 'collection':
        return PassportCollection.values.any((c) => c.id == local) ? StampEvent.collected(local!) : null;
      case 'chapter_opened':
        final chapter = payload['chapter'];
        return StampEvent.chapter(chapter is num ? '${chapter.toInt()}' : (_text(chapter) ?? '2'));
      case 'weekly_done':
        return ExpeditionGoal.values.any((g) => g.id == id) ? StampEvent.expedition(id!) : null;
      case 'companion':
        return const StampEvent.special(PassportSocial.companionId);
      default:
        return null;
    }
  }
}

/// The passport endpoints; tests use a fake.
abstract interface class PassportApi {
  Future<PassportServerState> state();
  Future<List<PassportServerEvent>> unseenEvents();
  Future<void> ack(int throughId);
  Future<PassportServerState?> profile(Map<String, Object?> fields);
  Future<void> share();
  Future<PassportServerState?> importV1(Map<String, Object?> body);
}

class HttpPassportApi implements PassportApi {
  HttpPassportApi({APIClient? client}) : _injected = client;

  final APIClient? _injected;

  APIClient get _client => _injected ?? APIClient();

  @override
  Future<PassportServerState> state() => _client.get(
    APIEndpoint.passport,
    (json) => PassportServerState.parse(json) ?? (throw const FormatException('Passport answer has no data')),
  );

  @override
  Future<List<PassportServerEvent>> unseenEvents() =>
      _client.get(APIEndpoint.passportEvents, PassportServerEvent.parseList, queryParameters: {'unseen': 1});

  @override
  Future<void> ack(int throughId) =>
      _client.post<void>(APIEndpoint.passportEventsAck, (_) {}, data: {'through_id': throughId});

  @override
  Future<PassportServerState?> profile(Map<String, Object?> fields) =>
      _client.put(APIEndpoint.passportProfile, PassportServerState.parse, data: fields);

  @override
  Future<void> share() => _client.post<void>(APIEndpoint.passportEvents, (_) {}, data: {'kind': 'share'});

  @override
  Future<PassportServerState?> importV1(Map<String, Object?> body) =>
      _client.post(APIEndpoint.passportImport, PassportServerState.parse, data: body);
}

/// A reveal waiting to play: the server event id (acked after it played),
/// what to show (null: nothing to show, acked all the same) and whether it
/// took something away (the shell then says "your passport was updated").
typedef PassportReveal = ({int id, StampEvent? event, bool revoked});

/// Keeps the cached passport in step with the account.
///
/// Refreshes on app start and foreground, when the passport screen opens
/// (then every 60 s while connected) and after a connect. New server events
/// wait in [takeReveals] for the shell, which plays them in order and acks.
class PassportClient {
  PassportClient({PassportApi? api, Future<String?> Function()? deviceId, ColituPassport Function()? passport})
    : api = api ?? HttpPassportApi(),
      _deviceId = deviceId ?? SecureTokenStore().readDeviceId,
      _passport = passport ?? (() => ColituPassport.I);

  static PassportClient I = PassportClient();

  final PassportApi api;
  final Future<String?> Function() _deviceId;
  final ColituPassport Function() _passport;

  /// The v1 progress of this device reached the account (or there was none).
  static const importedKey = 'v2_imported';

  /// The time zone offset last sent to the account.
  static const tzKey = 'tz_sent';

  /// Keys that belong to this device, not to the account: kept on sign-out.
  static const deviceKeys = {importedKey, 'sound', 'haptics', 'friends_ranking', 'intro_seen', 'friends'};

  final _reveals = <PassportReveal>[];
  var _lastQueued = 0;
  Future<bool>? _running;

  static var _loaded = false;

  /// Reads the cached passport (once per app start) and connects it to the
  /// account; removes the files of v1's minute counting in the tunnel.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    ColituPassport.I = ColituPassport(store: await PrefsPassportStore.load())..profileSink = I.sendProfile;
    unawaited(_removeV1Files());
  }

  static Future<void> _removeV1Files() async {
    try {
      final dir = VpnConstants.runDir;
      for (final name in ['passport_ticks.log', 'passport_state.json', 'passport_cc', 'passport_notify.json', 'passport_notified']) {
        final file = File(p.join(dir, name));
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
  }

  /// Fetches the account's passport; true when the server answered. One run
  /// at a time; a second call joins the running one.
  Future<bool> refresh() => _running ??= _refresh().whenComplete(() => _running = null);

  Future<bool> _refresh() async {
    final passport = _passport();
    final store = passport.store;
    try {
      // The v1 progress must reach the account before the server state
      // replaces it in the cache.
      if (!store.getBool(importedKey) && !await _importOnce(passport)) return false;
      var state = await api.state();
      final tz = DateTime.now().timeZoneOffset.inMinutes;
      if (!store.contains(tzKey) || store.getInt(tzKey) != tz) {
        final updated = await api.profile({'tz_offset_min': tz});
        store.setInt(tzKey, tz);
        if (updated != null) state = updated;
      }
      state.applyTo(passport);
      if (state.unseenEvents > 0) {
        for (final event in await api.unseenEvents()) {
          if (event.id <= _lastQueued) continue;
          _reveals.add((id: event.id, event: event.isRevoke ? null : event.toReveal(passport), revoked: event.isRevoke));
          _lastQueued = event.id;
        }
      }
      passport.reload();
      return true;
    } catch (error) {
      debugPrint('Passport refresh: $error');
      return false;
    }
  }

  /// Sends the v1 progress once; false when it has to be tried again.
  Future<bool> _importOnce(ColituPassport passport) async {
    final store = passport.store;
    final body = importPayload(passport, await _deviceId() ?? '');
    if (body == null) {
      store.setBool(importedKey, true);
      return true;
    }
    try {
      final merged = await api.importV1(body);
      store.setBool(importedKey, true);
      merged?.applyTo(passport);
      return true;
    } on APIException catch (error) {
      final status = error.statusCode ?? 0;
      // Imported before (409), or a body the server will never take: done.
      final done = error.backendCode == 'PASSPORT_ALREADY_IMPORTED' ||
          (status >= 400 && status < 500 && status != 401 && status != 408 && status != 429);
      if (done) store.setBool(importedKey, true);
      return done;
    }
  }

  /// The v1 progress kept on this device, for `POST /client/passport/import`;
  /// null when there is none.
  @visibleForTesting
  static Map<String, Object?>? importPayload(ColituPassport passport, String deviceId) {
    final stamps = [
      for (final s in ColituPassport.allStamps)
        if (passport.progressOf(s.code).unlocked)
          {
            'country': s.code,
            'pieces': passport.progressOf(s.code).pieces,
            'unlocked_at': DateTime.fromMillisecondsSinceEpoch(passport.progressOf(s.code).unlockedAt, isUtc: true).toIso8601String(),
          },
    ];
    final goals = passport.goals;
    final achievements = [for (final a in PassportAchievement.values) if (goals.achieved(a)) _serverId(a.id)];
    final collections = [for (final c in PassportCollection.values) if (goals.completed(c)) _serverId(c.id)];
    final expeditions = passport.weekly.total;
    final companion = passport.social.companion;
    if (stamps.isEmpty && achievements.isEmpty && expeditions == 0 && !companion) return null;
    return {
      'device_id': deviceId,
      'stamps': stamps,
      'achievements': achievements,
      'collections': collections,
      'expeditions_done': expeditions,
      'companion': companion,
      if (goals.nickname.isNotEmpty) 'nickname': goals.nickname,
      if (goals.title != null) 'title_id': _serverId(goals.title!),
      if (goals.cover != null) 'cover_id': goals.cover!.key,
    };
  }

  /// Server events not yet handed out, oldest first.
  List<PassportReveal> takeReveals() {
    final out = List.of(_reveals);
    _reveals.clear();
    return out;
  }

  /// Every event up to [throughId] has been shown.
  Future<void> ack(int throughId) async {
    try {
      await api.ack(throughId);
    } catch (error) {
      debugPrint('Passport ack: $error');
    }
  }

  /// The Story card was shared (the weekly share goal).
  Future<void> share() async {
    try {
      await api.share();
    } catch (error) {
      debugPrint('Passport share: $error');
    }
  }

  /// A changed nickname, title or cover. The cache already shows it; the
  /// server's answer (or the next refresh) has the last word.
  void sendProfile(Map<String, Object?> fields) {
    final passport = _passport();
    unawaited(() async {
      try {
        final state = await api.profile({...fields, 'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes});
        if (state != null) {
          state.applyTo(passport);
          passport.reload();
        }
      } catch (error) {
        debugPrint('Passport profile: $error');
      }
    }());
  }

  /// Signed out: the cached passport belonged to that account. Kept while
  /// this device's v1 progress has not reached an account yet.
  void signedOut() {
    final passport = _passport();
    final store = passport.store;
    _reveals.clear();
    _lastQueued = 0;
    if (!store.getBool(importedKey)) return;
    for (final key in store.snapshot().keys) {
      if (!deviceKeys.contains(key) && !key.startsWith('city_')) store.remove(key);
    }
    passport.reload();
  }
}
