import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';

/// Adaptive Connect telemetry: one small event per connect, recovery,
/// protocol switch, drop, latency probe and automatic choice, queued on the
/// device and sent at most hourly to `POST /client/ac-events`. Only
/// collected while the "usage statistics" switch is on (the same
/// switch as the counters). Events name nodes (UUIDs of the server list) and
/// protocols, never an account, an address or a site. Mirrors the Android
/// `ColituAcEvents`.
abstract final class ColituAcEvents {
  static const maxQueue = 1000;
  static const maxBatch = 300;
  static const maxMs = 600000;
  static const sendInterval = Duration(hours: 1);
  static const probeWindow = Duration(hours: 1);

  static const protocols = {
    'vless-reality',
    'vless-xhttp',
    'hysteria2',
    'trojan',
    'shadowsocks',
    'tuic',
  };
  static const reasons = {
    'timeout',
    'reset',
    'tls',
    'dns',
    'refused',
    'handshake',
    'blocked',
    'no_network',
    'core_crash',
    'auth',
    'quota',
    'network_change',
    'other',
  };
  static const _networkTypes = {'wifi', 'cellular', 'ethernet', 'other'};

  // ── Reason mapping ────────────────────────────────────────────────────

  /// Failure of this app (what the connect flow threw) to the telemetry
  /// reason:
  ///
  /// * `TimeoutException` (the panel or the engine did not answer in time)
  ///   -> `timeout`
  /// * `ColituVerifyException` without a tunnel failure (a transport came up
  ///   and carried nothing: DPI freeze or throttling) -> `blocked`; with a
  ///   `core_start_failed` / `core_crashed` / `core_not_running` /
  ///   `no_socket_fd` reason from the extension -> `core_crash`
  /// * `networkUnavailable` (the phone is offline, or every API base failed)
  ///   -> `no_network`
  /// * `unauthorized`, `tokenExpired`, `deviceDisconnected`, `deviceOverLimit`,
  ///   `emailNotVerified`, `subscriptionInactive`, `premiumRequired`,
  ///   `serverNotAllowed` -> `auth`
  /// * `freeDailyLimitReached`, backend `QUOTA_EXCEEDED` /
  ///   `FREE_DAILY_LIMIT_REACHED` -> `quota`
  /// * a code that already is a reason (`dns`, `tls`, `refused`, ...) is kept
  /// * everything else (panel errors, missing config, no servers, VPN
  ///   permission) -> `other`
  static String reasonOfError(Object? error) {
    if (error == null) return 'other';
    if (error is TimeoutException) return 'timeout';
    if (error is ColituVerifyException) {
      final failure = (error.tunnelFailure ?? '').trim();
      return failure.isEmpty ? 'blocked' : 'core_crash';
    }
    if (error is ColituPlanRequiredException) return 'auth';
    if (error is APIException) {
      final backend = (error.backendCode ?? '').toUpperCase();
      if (backend == 'QUOTA_EXCEEDED' || backend == 'FREE_DAILY_LIMIT_REACHED') {
        return 'quota';
      }
      return switch (error.code) {
        APIErrorCode.networkUnavailable => 'no_network',
        APIErrorCode.unauthorized ||
        APIErrorCode.tokenExpired ||
        APIErrorCode.deviceDisconnected ||
        APIErrorCode.deviceOverLimit ||
        APIErrorCode.emailNotVerified ||
        APIErrorCode.subscriptionInactive ||
        APIErrorCode.premiumRequired ||
        APIErrorCode.accountUnderReview ||
        APIErrorCode.accountBlocked ||
        APIErrorCode.serverNotAllowed => 'auth',
        APIErrorCode.freeDailyLimitReached => 'quota',
        _ => 'other',
      };
    }
    return reasonOf(error.toString());
  }

  /// A failure code as text: kept when it already is a reason, else mapped
  /// (`TIMEOUT`, `NETWORK_ERROR`, `VERIFY_FAILED`, `QUOTA_EXCEEDED`, ...).
  static String reasonOf(String? code) {
    final raw = (code ?? '').trim().toLowerCase();
    if (reasons.contains(raw)) return raw;
    return switch (raw.toUpperCase()) {
      'TIMEOUT' || 'TUNNEL_TIMEOUT' || 'UNREACHABLE' => 'timeout',
      'IO_ERROR' => 'reset',
      'NETWORK_ERROR' => 'no_network',
      'VERIFY_FAILED' => 'blocked',
      'ENGINE_FAILED' || 'TUN_FAILED' => 'core_crash',
      'AUTH_EXPIRED' ||
      'UNAUTHORIZED' ||
      'ENTITLEMENT_INACTIVE' ||
      'ENTITLEMENT_EXPIRED' ||
      'PREMIUM_REQUIRED' ||
      'SERVER_NOT_ALLOWED' => 'auth',
      'QUOTA_EXCEEDED' || 'FREE_DAILY_LIMIT_REACHED' => 'quota',
      'NETWORK_CHANGE' => 'network_change',
      _ => 'other',
    };
  }

  // ── Event builders (null when a required field is missing or invalid) ──

  static String? _node(String? id) {
    final v = id?.trim().toLowerCase();
    return v != null && v.length >= 8 && v.length <= 64 ? v : null;
  }

  static String? _protocol(String? p) {
    final v = p?.trim().toLowerCase();
    return v != null && protocols.contains(v) ? v : null;
  }

  static int _clamp(int ms) => ms < 0 ? 0 : (ms > maxMs ? maxMs : ms);
  static String _outcome(bool ok) => ok ? 'ok' : 'fail';

  static Map<String, dynamic>? connect({
    required String? nodeId,
    required String? protocol,
    required bool ok,
    String? code,
    required int ms,
    required bool firstTry,
    required bool auto,
  }) {
    final n = _node(nodeId);
    final p = _protocol(protocol);
    if (n == null || p == null) return null;
    return {
      'kind': 'connect',
      'node_id': n,
      'protocol': p,
      'outcome': _outcome(ok),
      if (!ok) 'reason': reasonOf(code),
      'ms': _clamp(ms),
      'first_try': firstTry,
      'mode': auto ? 'auto' : 'manual',
    };
  }

  static Map<String, dynamic>? recovery({
    required String? nodeId,
    required String? protocol,
    String? toProtocol,
    required bool ok,
    String? code,
    required int ms,
    int? detectMs,
    required bool spare,
  }) {
    final n = _node(nodeId);
    final p = _protocol(protocol);
    if (n == null || p == null) return null;
    final to = _protocol(toProtocol);
    return {
      'kind': 'recovery',
      'node_id': n,
      'protocol': p,
      'to_protocol': ?to,
      'outcome': _outcome(ok),
      if (!ok) 'reason': reasonOf(code),
      'ms': _clamp(ms),
      if (detectMs != null) 'detect_ms': _clamp(detectMs),
      'spare': spare,
    };
  }

  static Map<String, dynamic>? switched({
    required String? from,
    required String? to,
    required bool ok,
    required bool flap,
  }) {
    final p = _protocol(from);
    final target = _protocol(to);
    // The panel needs both ends, and a report with one invalid event is
    // refused whole: a recovery that reached no protocol is told by its
    // recovery event alone. Sending it anyway lost every hourly batch with a
    // failed recovery in it, so the panel only ever saw iOS successes.
    if (p == null || target == null) return null;
    return {
      'kind': 'switch',
      'protocol': p,
      'to_protocol': target,
      'outcome': _outcome(ok),
      'flap': flap,
    };
  }

  static Map<String, dynamic>? drop({
    required String? nodeId,
    required String? protocol,
    String? code,
    required int minutes,
  }) {
    final n = _node(nodeId);
    final p = _protocol(protocol);
    if (n == null || p == null) return null;
    return {
      'kind': 'drop',
      'node_id': n,
      'protocol': p,
      'reason': reasonOf(code),
      'minutes': minutes < 0 ? 0 : (minutes > 100000 ? 100000 : minutes),
    };
  }

  /// A latency measurement; a failed probe carries no time.
  static Map<String, dynamic>? probe(String? nodeId, int? ms) {
    final n = _node(nodeId);
    if (n == null) return null;
    return {
      'kind': 'probe',
      'node_id': n,
      'outcome': ms != null ? 'ok' : 'fail',
      if (ms != null) 'ms': _clamp(ms),
    };
  }

  /// An automatic choice: the node picked, its measured ping, and the node
  /// with the lowest measured ping among [candidates] (id to fresh ping,
  /// null = none). Null when the chosen node has no measurement or nothing
  /// was measured, so `best_ms <= ms` always holds.
  static Map<String, dynamic>? choice(
    String? chosenId,
    Map<String, int?> candidates,
  ) {
    final chosen = _node(chosenId);
    if (chosen == null) return null;
    final ms = candidates[chosenId];
    if (ms == null || ms < 0) return null;
    MapEntry<String, int?>? best;
    for (final entry in candidates.entries) {
      final v = entry.value;
      if (v == null || v < 0) continue;
      if (best == null || v < best.value!) best = entry;
    }
    if (best == null) return null;
    final bestMs = best.value! <= ms ? best.value! : ms;
    final bestId = best.value! <= ms ? best.key : chosenId!;
    return {
      'kind': 'choice',
      'node_id': chosen,
      'ms': _clamp(ms),
      'best_node_id': _node(bestId) ?? chosen,
      'best_ms': _clamp(bestMs),
      'mode': 'auto',
    };
  }

  /// The link type for the request: wifi / cellular / ethernet / other, else
  /// empty (none, unknown).
  static String networkTypeOf(String? link) {
    final v = link?.trim().toLowerCase();
    return v != null && _networkTypes.contains(v) ? v : '';
  }

  /// The body of `POST /client/ac-events` for [batch] (all of one network).
  static Map<String, dynamic> requestBody(
    String appVersion,
    String token,
    String type,
    List<AcEntry> batch,
  ) => {
    'platform': ColituMetricsData.platform,
    'app_version': appVersion,
    'network_token': token,
    'network_type': networkTypeOf(type),
    'events': [for (final e in batch.take(maxBatch)) e.event],
  };
}

/// One queued event with the network token and link type of when it
/// happened.
class AcEntry {
  AcEntry(this.event, this.token, this.type, this.at);

  final Map<String, dynamic> event;
  final String token;
  final String type;
  final int at;
}

/// FIFO queue capped at [cap]; the oldest events are dropped first. Pure, so
/// it is unit tested.
class AcQueue {
  AcQueue({this.cap = ColituAcEvents.maxQueue});

  final int cap;
  final List<AcEntry> entries = [];

  bool get isEmpty => entries.isEmpty;

  void add(Map<String, dynamic> event, String token, String type, int atMs) {
    // At most the last probe of a node per hour.
    if (event['kind'] == 'probe') {
      final id = event['node_id'];
      final window = ColituAcEvents.probeWindow.inMilliseconds;
      entries.removeWhere(
        (e) =>
            e.event['kind'] == 'probe' &&
            e.event['node_id'] == id &&
            atMs - e.at >= 0 &&
            atMs - e.at <= window,
      );
    }
    entries.add(AcEntry(event, token, type, atMs));
    while (entries.length > cap) {
      entries.removeAt(0);
    }
  }

  /// The next request: the oldest event's network, up to
  /// [ColituAcEvents.maxBatch] events of that network in order.
  List<AcEntry> nextBatch() {
    if (entries.isEmpty) return const [];
    final first = entries.first;
    return entries
        .where((e) => e.token == first.token && e.type == first.type)
        .take(ColituAcEvents.maxBatch)
        .toList();
  }

  void remove(Iterable<AcEntry> sent) {
    final set = sent.toSet();
    entries.removeWhere(set.contains);
  }

  String encode() => jsonEncode([
    for (final e in entries) {'e': e.event, 't': e.token, 'n': e.type, 'a': e.at},
  ]);

  static AcQueue decode(String? raw, {int cap = ColituAcEvents.maxQueue}) {
    final queue = AcQueue(cap: cap);
    if (raw == null || raw.isEmpty) return queue;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final item in list) {
          if (item is! Map || item['e'] is! Map) continue;
          queue.entries.add(
            AcEntry(
              Map<String, dynamic>.from(item['e'] as Map),
              item['t'] is String ? item['t'] as String : '',
              item['n'] is String ? item['n'] as String : '',
              item['a'] is num ? (item['a'] as num).toInt() : 0,
            ),
          );
        }
      }
    } catch (_) {
      return AcQueue(cap: cap);
    }
    while (queue.entries.length > cap) {
      queue.entries.removeAt(0);
    }
    return queue;
  }
}

/// Local queue and hourly sender of the Adaptive Connect events. Shares the
/// "usage statistics" switch with [ColituMetrics].
class ColituAcEventStore {
  ColituAcEventStore({
    required ColituMetrics metrics,
    ColituKv? store,
    DateTime Function()? clock,
    ColituPostJson? post,
    Future<String> Function()? appVersion,
  }) : _metrics = metrics,
       _store = store ?? PrefsColituKv(),
       _clock = clock ?? DateTime.now,
       _post = post ?? colituPostJson,
       _appVersion = appVersion ?? colituAppVersion {
    // Turning the statistics off also empties this queue.
    _metrics.onDisabled = () => unawaited(clear());
  }

  static final ColituAcEventStore instance = ColituAcEventStore(
    metrics: ColituMetrics.instance,
  );

  static const _kQueue = 'colituAcEvents';
  static const _kLastAttempt = 'colituAcEventsLastAttempt';

  final ColituMetrics _metrics;
  final ColituKv _store;
  final DateTime Function() _clock;
  final ColituPostJson _post;
  final Future<String> Function() _appVersion;

  Future<void> _chain = Future.value();
  AcQueue? _queue;

  Future<void> _run(Future<void> Function() action) {
    final next = _chain.then((_) async {
      try {
        await action();
      } catch (e) {
        debugPrint('AC events step failed: $e');
      }
    });
    _chain = next;
    return next;
  }

  Future<AcQueue> _current() async =>
      _queue ??= AcQueue.decode(await _store.read(_kQueue));

  Future<void> idle() => _run(() async {});

  Future<int> length() async {
    var n = 0;
    await _run(() async => n = (await _current()).entries.length);
    return n;
  }

  /// The queued events, oldest first (tests).
  Future<List<Map<String, dynamic>>> snapshotEvents() async {
    var list = <Map<String, dynamic>>[];
    await _run(() async {
      list = [for (final e in (await _current()).entries) e.event];
    });
    return list;
  }

  /// Queues [event] (null is ignored) unless the statistics switch is off.
  void record(
    Map<String, dynamic>? event, {
    required String token,
    required String linkType,
  }) {
    if (event == null) return;
    final at = _clock().millisecondsSinceEpoch;
    unawaited(
      _run(() async {
        if (!await _metrics.isEnabled()) return;
        final queue = await _current();
        queue.add(event, token, ColituAcEvents.networkTypeOf(linkType), at);
        await _store.write(_kQueue, queue.encode());
      }),
    );
  }

  /// Forgets every queued event (the statistics switch was turned off).
  Future<void> clear() => _run(() async {
    _queue = AcQueue();
    await _store.write(_kQueue, null);
  });

  /// Sends the queued events when due (hourly). Safe to call often; never
  /// throws. One request per network, a few at most per run; the rest
  /// follows the next hour.
  Future<void> maybeSend() => _run(() async {
    final queue = await _current();
    if (queue.isEmpty || !await _metrics.isEnabled()) return;
    final now = _clock();
    final lastRaw = int.tryParse(await _store.read(_kLastAttempt) ?? '');
    final last = lastRaw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastRaw);
    if (!ColituMetricsRules.due(
      enabled: true,
      hasData: true,
      lastAttempt: last,
      now: now,
      every: ColituAcEvents.sendInterval,
    )) {
      return;
    }
    await _store.write(_kLastAttempt, '${now.millisecondsSinceEpoch}');
    for (var round = 0; round < 3; round++) {
      final batch = queue.nextBatch();
      if (batch.isEmpty) return;
      final body = ColituAcEvents.requestBody(
        await _appVersion(),
        batch.first.token,
        batch.first.type,
        batch,
      );
      int? status;
      try {
        await _post(APIEndpoint.clientAcEvents, body);
        status = 202;
      } catch (e) {
        status = colituStatusOf(e);
      }
      if (colituOutcomeFor(status) != ColituMetricsOutcome.reset) return;
      queue.remove(batch);
      await _store.write(_kQueue, queue.encode());
    }
  });
}
