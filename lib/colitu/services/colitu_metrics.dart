import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';

/// Small string store for the statistics and survey state. The default keeps
/// it in the app's preferences; tests use an in-memory map.
abstract class ColituKv {
  Future<String?> read(String key);

  /// A null [value] deletes the key.
  Future<void> write(String key, String? value);
}

class PrefsColituKv implements ColituKv {
  late final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);
}

/// What to do with the stored numbers after the panel answered (or not).
enum ColituMetricsOutcome { reset, keep }

/// `POST` of a JSON body to a panel path; throws [APIException] on any
/// non-2xx answer. Replaced in tests.
typedef ColituPostJson = Future<void> Function(
  String path,
  Map<String, dynamic> body,
);

Future<void> colituPostJson(String path, Map<String, dynamic> body) =>
    APIClient().postRenewing<void>(path, (_) {}, data: () => body);

/// The app version for the reports ("5.8.1"), empty when unreadable.
Future<String> colituAppVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return '';
  }
}

/// 2xx and 400 (bad data, it would never be accepted) reset what was sent;
/// 429, 5xx, no answer or anything else keep it for the next time.
ColituMetricsOutcome colituOutcomeFor(int? status) =>
    status != null && ((status >= 200 && status < 300) || status == 400)
    ? ColituMetricsOutcome.reset
    : ColituMetricsOutcome.keep;

/// The status of a failed request for [colituOutcomeFor]; null when there
/// was no answer.
int? colituStatusOf(Object error) =>
    error is APIException ? error.statusCode : null;

/// Usage statistics (kept by the server as daily totals, not linked to the
/// account or device): aggregate counters, three histograms and the
/// names of the features used, kept on the device since the last accepted
/// report. Nothing identifies an account, a device, an IP address or a site.
/// This class is the plain data (unit tested); [ColituMetrics] stores and
/// sends it. Mirrors the Android `ColituMetricsData`.
class ColituMetricsData {
  static const maxCount = 10000;
  static const buckets = 9;
  static const platform = 'ios';

  /// Upper bounds in ms of the first eight buckets; the ninth is slower than
  /// the last.
  static const boundsMs = [500, 1000, 2000, 3000, 5000, 8000, 15000, 30000];

  static const counterNames = {
    'connect_attempts',
    'connect_successes',
    'first_connect_attempts',
    'first_connect_successes',
    'sessions',
    'unexpected_disconnects',
    'functional_checks',
    'functional_ok',
    'recoveries',
    'recovery_successes',
    'protocol_switches',
    'protocol_switch_successes',
    'flaps',
  };
  static const histogramNames = {'connect_ms', 'recovery_ms', 'detection_ms'};
  static const featureNames = {
    'split_tunnel',
    'shield',
    'ad_block',
    'advanced_mode',
    'multihop',
    'auto_connect',
    'kill_switch',
    'manual_server',
    'custom_dns',
  };

  final Map<String, int> counters = {};
  final Map<String, List<int>> histograms = {};
  final Set<String> features = {};

  /// The bucket of [ms]: the first bound it does not exceed, else the last
  /// (slower) one.
  static int bucketOf(int ms) {
    final i = boundsMs.indexWhere((bound) => ms <= bound);
    return i < 0 ? buckets - 1 : i;
  }

  /// Adds [n] (negative to take back an abandoned attempt) to a known
  /// counter, kept within 0..[maxCount].
  void add(String name, [int n = 1]) {
    if (!counterNames.contains(name) || n == 0) return;
    final value = ((counters[name] ?? 0) + n).clamp(0, maxCount);
    if (value == 0) {
      counters.remove(name);
    } else {
      counters[name] = value;
    }
  }

  /// Puts [ms] into the matching bucket of a known histogram.
  void observe(String name, int ms) {
    if (!histogramNames.contains(name) || ms < 0) return;
    final list = histograms.putIfAbsent(name, () => List.filled(buckets, 0));
    final i = bucketOf(ms);
    list[i] = list[i] + 1 > maxCount ? maxCount : list[i] + 1;
  }

  void feature(String name) {
    if (featureNames.contains(name)) features.add(name);
  }

  bool get isEmpty =>
      counters.isEmpty && histograms.isEmpty && features.isEmpty;

  ColituMetricsData copy() {
    final c = ColituMetricsData();
    c.counters.addAll(counters);
    histograms.forEach((k, v) => c.histograms[k] = [...v]);
    c.features.addAll(features);
    return c;
  }

  void clear() {
    counters.clear();
    histograms.clear();
    features.clear();
  }

  /// Removes what was sent ([sent] is a [copy] taken before the request),
  /// keeping anything recorded since.
  void subtract(ColituMetricsData sent) {
    sent.counters.forEach((k, v) => add(k, -v));
    sent.histograms.forEach((k, v) {
      final mine = histograms[k];
      if (mine == null) return;
      for (var i = 0; i < buckets; i++) {
        mine[i] = (mine[i] - v[i]).clamp(0, maxCount);
      }
      if (mine.every((n) => n == 0)) histograms.remove(k);
    });
    features.removeAll(sent.features);
  }

  /// The body of `POST /client/metrics`: non-zero counters and non-empty
  /// histograms only, every number capped at [maxCount].
  Map<String, dynamic> toRequest(String appVersion, {required bool killSwitch}) => {
    'platform': platform,
    'app_version': appVersion,
    'counters': {
      for (final e in counters.entries)
        if (e.value > 0) e.key: e.value > maxCount ? maxCount : e.value,
    },
    'histograms': {
      for (final e in histograms.entries)
        if (e.value.any((n) => n > 0))
          e.key: [for (final n in e.value) n > maxCount ? maxCount : n],
    },
    'kill_switch': killSwitch,
    'features': features.toList()..sort(),
  };

  String encode() => jsonEncode({'c': counters, 'h': histograms, 'f': features.toList()});

  static ColituMetricsData decode(String? raw) {
    final data = ColituMetricsData();
    if (raw == null || raw.isEmpty) return data;
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return data;
      final c = root['c'];
      if (c is Map) {
        c.forEach((k, v) {
          if (k is String && v is num) data.add(k, v.toInt());
        });
      }
      final h = root['h'];
      if (h is Map) {
        h.forEach((k, v) {
          if (k is! String || !histogramNames.contains(k) || v is! List) return;
          final list = [
            for (var i = 0; i < buckets; i++)
              i < v.length && v[i] is num ? (v[i] as num).toInt().clamp(0, maxCount) : 0,
          ];
          if (list.any((n) => n > 0)) data.histograms[k] = list;
        });
      }
      final f = root['f'];
      if (f is List) {
        for (final name in f) {
          if (name is String) data.feature(name);
        }
      }
    } catch (_) {
      return ColituMetricsData();
    }
    return data;
  }
}

/// Pure rules the controller uses for the statistics (unit tested).
abstract final class ColituMetricsRules {
  static const flapWindow = Duration(minutes: 2);

  /// A flap: the switch from [from] to [to] undoes the previous successful
  /// one (to -> from) less than two minutes ago. [last] is that switch.
  static bool isFlap(
    ({String from, String to, DateTime at})? last,
    String from,
    String to,
    DateTime now,
  ) {
    if (last == null || last.from != to || last.to != from) return false;
    final age = now.difference(last.at);
    return !age.isNegative && age <= flapWindow;
  }

  /// True when a report is due: enabled, something to send and 6 hours since
  /// the last try (a clock set back also allows one).
  static bool due({
    required bool enabled,
    required bool hasData,
    required DateTime? lastAttempt,
    required DateTime now,
    Duration every = ColituMetrics.sendInterval,
  }) =>
      enabled &&
      hasData &&
      (lastAttempt == null ||
          now.isBefore(lastAttempt) ||
          now.difference(lastAttempt) >= every);
}

/// Local store and sender of the usage statistics (default on). With the
/// setting off nothing is collected or sent and the stored numbers are gone.
/// Sent at most every [sendInterval]; never blocks the UI. All mutations run
/// one after another on a private chain, so callers can fire and forget.
class ColituMetrics {
  ColituMetrics({
    ColituKv? store,
    DateTime Function()? clock,
    ColituPostJson? post,
    Future<String> Function()? appVersion,
    void Function()? onDisabled,
  }) : _store = store ?? PrefsColituKv(),
       _clock = clock ?? DateTime.now,
       _post = post ?? colituPostJson,
       _appVersion = appVersion ?? colituAppVersion,
       _onDisabled = onDisabled;

  static final ColituMetrics instance = ColituMetrics();

  static const sendInterval = Duration(hours: 6);

  static const _kEnabled = 'colituMetricsEnabled';
  static const _kData = 'colituMetricsData';
  static const _kLastAttempt = 'colituMetricsLastAttempt';
  static const _kFirstDone = 'colituMetricsFirstConnectDone';

  final ColituKv _store;
  final DateTime Function() _clock;
  final ColituPostJson _post;
  final Future<String> Function() _appVersion;

  /// Called after the switch went off (the AC event queue is cleared too).
  void Function()? _onDisabled;
  set onDisabled(void Function()? value) => _onDisabled = value;

  Future<void> _chain = Future.value();
  var _loaded = false;
  var _enabled = true;
  var _firstDone = false;
  var _data = ColituMetricsData();

  Future<void> _run(Future<void> Function() action) {
    final next = _chain.then((_) async {
      try {
        await _load();
        await action();
      } catch (e) {
        debugPrint('Statistics step failed: $e');
      }
    });
    _chain = next;
    return next;
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    _enabled = (await _store.read(_kEnabled)) != '0';
    _firstDone = (await _store.read(_kFirstDone)) == '1';
    _data = ColituMetricsData.decode(await _store.read(_kData));
  }

  /// Waits for everything queued so far (tests).
  Future<void> idle() => _run(() async {});

  /// The "Usage statistics" switch (default on).
  Future<bool> isEnabled() async {
    var value = true;
    await _run(() async => value = _enabled);
    return value;
  }

  /// Off: the stored numbers and the queued events are deleted and nothing
  /// more is collected.
  Future<void> setEnabled(bool value) => _run(() async {
    _enabled = value;
    await _store.write(_kEnabled, value ? '1' : '0');
    if (!value) {
      _data = ColituMetricsData();
      await _store.write(_kData, null);
      _onDisabled?.call();
    }
  });

  Future<void> _mutate(void Function(ColituMetricsData) change) =>
      _run(() async {
        if (!_enabled) return;
        change(_data);
        await _store.write(_kData, _data.encode());
      });

  void count(String name, [int n = 1]) => unawaited(_mutate((d) => d.add(name, n)));
  void observe(String name, int ms) => unawaited(_mutate((d) => d.observe(name, ms)));
  void features(Iterable<String> names) => unawaited(
    _mutate((d) {
      for (final name in names) {
        d.feature(name);
      }
    }),
  );

  /// True until the first connection attempt of this install has had its
  /// result.
  Future<bool> isFirstConnect() async {
    var value = false;
    await _run(() async => value = !_firstDone);
    return value;
  }

  Future<void> markFirstDone() => _run(() async {
    _firstDone = true;
    await _store.write(_kFirstDone, '1');
  });

  /// A copy of what is stored (tests and the report).
  Future<ColituMetricsData> snapshot() async {
    late ColituMetricsData copy;
    await _run(() async => copy = _data.copy());
    return copy;
  }

  /// Sends the report when it is due. Safe to call often; never throws.
  /// [killSwitch]: the strict kill switch is on.
  Future<void> maybeSend({required bool killSwitch}) => _run(() async {
    final now = _clock();
    final lastRaw = int.tryParse(await _store.read(_kLastAttempt) ?? '');
    final last = lastRaw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastRaw);
    if (!ColituMetricsRules.due(
      enabled: _enabled,
      hasData: !_data.isEmpty,
      lastAttempt: last,
      now: now,
    )) {
      return;
    }
    await _store.write(_kLastAttempt, '${now.millisecondsSinceEpoch}');
    final sent = _data.copy();
    if (killSwitch) sent.feature('kill_switch');
    final body = sent.toRequest(await _appVersion(), killSwitch: killSwitch);
    int? status;
    try {
      await _post(APIEndpoint.clientMetrics, body);
      status = 202;
    } catch (e) {
      status = colituStatusOf(e);
    }
    if (colituOutcomeFor(status) == ColituMetricsOutcome.reset) {
      _data.subtract(sent);
      await _store.write(_kData, _data.encode());
    }
  });
}
