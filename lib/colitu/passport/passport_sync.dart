import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';

/// One connected minute written by the tunnel extension.
typedef PassportTick = ({int at, String country});

/// How passport minutes reach the app on iOS.
///
/// iOS does not run the app in the background, so the packet tunnel (alive
/// as long as the VPN is on) appends `<epoch ms>,<CC>` to
/// run/passport_ticks.log once per connected minute, with the country the app
/// wrote to run/passport_cc for this connection. When the app is in the
/// foreground it replays the new lines, oldest first, through
/// [ColituPassport.tick] with their own time stamps: the same rules as
/// Android (runs of five minutes, the 10th and 60th minute of each local day,
/// at most two pieces a day) give the same result, whenever the app opens.
/// A cursor (the last replayed time) makes every line count once.
abstract final class PassportTickLog {
  static const fileName = 'passport_ticks.log';
  static const countryFile = 'passport_cc';
  static const notifyFile = 'passport_notify.json';

  /// Lines closer than this are one minute written twice (two tunnels).
  static const minGapMs = 30000;

  /// Lines newer than [after], in time order, without duplicates and
  /// without times in the future (a wrong clock must not earn days ahead).
  static List<PassportTick> parse(String text, {required int after, required int now}) {
    final ticks = <PassportTick>[];
    for (final line in const LineSplitter().convert(text)) {
      final parts = line.trim().split(',');
      if (parts.length != 2) continue;
      final at = int.tryParse(parts[0]);
      final country = ColituPassport.normalize(parts[1]);
      if (at == null || country == null || at <= after || at > now + 60000) continue;
      ticks.add((at: at, country: country));
    }
    ticks.sort((a, b) => a.at.compareTo(b.at));
    final out = <PassportTick>[];
    var last = after;
    for (final t in ticks) {
      if (t.at - last < minGapMs) continue;
      out.add(t);
      last = t.at;
    }
    return out;
  }

  /// Replays the new minutes; returns how many were counted.
  static int replay(ColituPassport passport, String text) {
    final store = passport.store;
    final after = store.getInt('ext_cursor');
    final ticks = parse(text, after: after, now: passport.now().millisecondsSinceEpoch);
    for (final t in ticks) {
      passport.tick(t.country, at: t.at);
    }
    if (ticks.isNotEmpty) store.setInt('ext_cursor', ticks.last.at);
    return ticks.length;
  }
}

/// Loads the passport, keeps the tunnel's run files in step with it and
/// sends the optional anonymous counters.
abstract final class PassportSync {
  static var _loaded = false;

  /// Reads the saved passport (once per app start).
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    ColituPassport.I = ColituPassport(store: await PrefsPassportStore.load());
  }

  static String? get _runDir {
    try {
      return VpnConstants.runDir;
    } catch (_) {
      return null;
    }
  }

  /// Counts the minutes the tunnel recorded since the last look.
  static Future<int> consume({String? runDir}) async {
    final dir = runDir ?? _runDir;
    if (dir == null) return 0;
    try {
      final file = File(p.join(dir, PassportTickLog.fileName));
      if (!await file.exists()) return 0;
      final n = PassportTickLog.replay(ColituPassport.I, await file.readAsString());
      if (n > 0) ColituPassport.I.reload();
      return n;
    } catch (error) {
      debugPrint('Passport ticks: $error');
      return 0;
    }
  }

  /// Tells the tunnel which country this connection counts for, and the
  /// texts of the optional notifications in the app's language.
  static Future<void> writeConnection(String? countryCode, {String? runDir}) async {
    final dir = runDir ?? _runDir;
    final cc = ColituPassport.normalize(countryCode);
    if (dir == null || cc == null) return;
    try {
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, PassportTickLog.countryFile)).writeAsString(cc, flush: true);
      await File(p.join(dir, PassportTickLog.notifyFile)).writeAsString(jsonEncode(notifyConfig(ColituPassport.I, cc)));
    } catch (error) {
      debugPrint('Passport country: $error');
    }
  }

  /// What the tunnel needs to post the passport notifications by itself
  /// (the app may not run): on/off, tester, which stamps are still locked
  /// and the texts. Contains no account or connection data.
  @visibleForTesting
  static Map<String, Object> notifyConfig(ColituPassport passport, String cc) {
    final loc = ColituLoc.I;
    final country = loc.countryName(cc);
    final (_, piecesToday) = passport.today;
    // The next piece goes to this stamp, or to the last unlocked one.
    final target = passport.unlockedAnywhere(cc) ? cc : passport.store.getString('last_unlocked');
    return {
      'on': passport.notify,
      'tester': passport.tester,
      'locked': [if (!passport.unlockedAnywhere(cc)) cc],
      'countries': {
        cc: {
          'unlockTitle': loc.format('passport.n.unlockedTitle', {'country': country}),
          'unlockBody': loc['passport.n.unlockedBody'],
        },
      },
      if (target != null && (passport.tester || piecesToday < ColituPassport.pieceMinutes.length)) ...{
        'pieceTitle': loc.format('passport.n.pieceTitle', {'country': loc.countryName(target)}),
        'pieceBody': loc['passport.n.levelBody'],
      },
    };
  }

  /// The anonymous daily counters, when turned on (no identifier at all:
  /// the request carries no token and no device id).
  static Future<void> sendMetrics({APIClient? client}) async {
    final body = ColituPassport.I.social.metricsPayload();
    if (body == null) return;
    try {
      await (client ?? APIClient()).post<void>(
        APIEndpoint.passportMetrics,
        (_) {},
        data: body,
        authenticated: false,
      );
      ColituPassport.I.social.metricsSent();
    } catch (error) {
      debugPrint('Passport metrics: $error');
    }
  }
}
