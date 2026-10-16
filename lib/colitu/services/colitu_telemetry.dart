import 'dart:async';

import 'package:colitu_vpn/colitu/services/colitu_ac_events.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';

/// The connection flow's side of the usage statistics and the Adaptive
/// Connect events: it keeps the open connect attempt and the open recovery
/// and turns their results into counters, histograms and events (see
/// [ColituMetrics], [ColituAcEventStore]). The controller only calls the
/// small methods below; every call is fire-and-forget and cheap when the
/// statistics switch is off. Mirrors the Android controller's
/// `beginMetricAttempt` / `endMetricAttempt` / `beginMetricRecovery` /
/// `endMetricRecovery` / `abandonMetrics`.
class ColituTelemetry {
  ColituTelemetry({
    ColituMetrics? metrics,
    ColituAcEventStore? events,
    DateTime Function()? clock,
    this.tokenOf,
    this.linkOf,
    this.isNode,
  }) : metrics = metrics ?? ColituMetrics.instance,
       events = events ?? ColituAcEventStore.instance,
       _clock = clock ?? DateTime.now;

  static final ColituTelemetry instance = ColituTelemetry();

  final ColituMetrics metrics;
  final ColituAcEventStore events;
  final DateTime Function() _clock;

  /// The "Usage statistics" switch. Off deletes every stored
  /// counter and queued event and stops collection.
  Future<void> setStatisticsEnabled(bool on) async {
    await metrics.setEnabled(on);
    if (!on) await events.clear();
  }

  Future<bool> statisticsEnabled() => metrics.isEnabled();

  /// The network token of the last `/servers` answer made with the VPN off
  /// (empty when none).
  String Function()? tokenOf;

  /// The link kind (wifi, cellular, ethernet, other).
  String Function()? linkOf;

  /// True for an id of a node of the server list (never a multihop route).
  bool Function(String? id)? isNode;

  // ── Open connect attempt ──────────────────────────────────────────────
  DateTime? _attemptAt;
  var _first = false;
  var _auto = false;
  String? _node;
  String? _protocol;
  var _fallbacks = 0;
  var _attemptSeq = 0;

  // ── Open recovery ─────────────────────────────────────────────────────
  DateTime? _recoveryAt;
  String? _recoveryFrom;
  String? _recoveryNode;
  String? _recoveryProtocol;
  int? _recoveryDetectMs;
  var _recoverySpare = false;
  ({String from, String to, DateTime at})? _lastSwitch;

  // ── The live connection, for drop events ──────────────────────────────
  String? _upNode;
  String? _upProtocol;
  DateTime? _upAt;

  bool get connectOpen => _attemptAt != null;
  bool get recoveryOpen => _recoveryAt != null;

  void _record(Map<String, dynamic>? event) {
    if (event == null) return;
    events.record(
      event,
      token: tokenOf?.call() ?? '',
      linkType: linkOf?.call() ?? '',
    );
  }

  bool _nodeOk(String? id) => id != null && (isNode?.call(id) ?? true);

  // ── Connect ───────────────────────────────────────────────────────────

  /// A connect attempt starts ([auto]: the automatic mode picks the
  /// server). A previous attempt that never settled is taken back. Returns
  /// the id of this attempt, for [isCurrentAttempt] and the id arguments
  /// of [endConnect] / [abandonConnect]: an older connect that finishes
  /// late can then not close the newer attempt.
  int beginConnect({required bool auto}) {
    abandonConnect();
    _attemptAt = _clock();
    _auto = auto;
    _node = null;
    _protocol = null;
    _fallbacks = 0;
    final seq = ++_attemptSeq;
    metrics.count('connect_attempts');
    metrics.isFirstConnect().then((first) {
      // Only when this attempt is still the open one.
      if (seq != _attemptSeq || _attemptAt == null) return;
      _first = first;
      if (first) metrics.count('first_connect_attempts');
    });
    return seq;
  }

  /// [id] (from [beginConnect]) is the open attempt.
  bool isCurrentAttempt(int id) => _attemptAt != null && id == _attemptSeq;

  /// The attempt is on [nodeId] with [protocol]; [fallbacks] is how many
  /// servers and transports were tried before this one (0: the first choice).
  void tryingConnect({String? nodeId, String? protocol, int? fallbacks}) {
    if (_attemptAt == null) return;
    if (nodeId != null) _node = nodeId;
    if (protocol != null) _protocol = protocol;
    if (fallbacks != null) _fallbacks = fallbacks;
  }

  /// The attempt moves on to the server [nodeId] (null: a multihop route,
  /// which is no node). The transport of an earlier server is forgotten, so a
  /// failure before any transport of this one was chosen names the server it
  /// was on and no protocol, never a mix of two.
  void tryingServer({String? nodeId, int? fallbacks}) {
    if (_attemptAt == null) return;
    _node = nodeId;
    _protocol = null;
    if (fallbacks != null) _fallbacks = fallbacks;
  }

  /// The attempt settled. A success names the node and protocol that carry
  /// traffic; a failure gives the [reason] (see
  /// [ColituAcEvents.reasonOfError]). No-op without an open attempt.
  void endConnect({
    required bool ok,
    String? nodeId,
    String? protocol,
    String? reason,
    int? id,
  }) {
    final at = _attemptAt;
    if (at == null || (id != null && id != _attemptSeq)) return;
    _attemptAt = null;
    final ms = _clock().difference(at).inMilliseconds;
    final first = _first;
    _first = false;
    final node = nodeId ?? _node;
    final proto = protocol ?? _protocol;
    // Internet verified through the tunnel: once per connect, not once per
    // transport tried (blocked transports dragged it to ~60 %). An offline
    // phone is not a failed check.
    if (ok || reason != 'networkUnavailable') functionalCheck(ok: ok);
    if (ok) {
      metrics.count('connect_successes');
      metrics.count('sessions');
      metrics.observe('connect_ms', ms);
      if (first) metrics.count('first_connect_successes');
      _upNode = node;
      _upProtocol = proto;
      _upAt = _clock();
    }
    if (_nodeOk(node)) {
      _record(
        ColituAcEvents.connect(
          nodeId: node,
          protocol: proto,
          ok: ok,
          code: reason,
          ms: ms,
          firstTry: _fallbacks == 0,
          auto: _auto,
        ),
      );
    }
    if (first) unawaited(metrics.markFirstDone());
  }

  /// The user cancelled, a newer connect took over or the device was paused:
  /// neither a success nor a failure.
  void abandonConnect({int? id}) {
    if (id != null && id != _attemptSeq) return;
    if (_attemptAt != null) {
      metrics.count('connect_attempts', -1);
      if (_first) metrics.count('first_connect_attempts', -1);
    }
    _attemptAt = null;
    _first = false;
    _attemptSeq++;
  }

  /// A connect ended with internet verified through the tunnel ([ok]) or
  /// without it.
  void functionalCheck({required bool ok}) {
    metrics.count('functional_checks');
    if (ok) metrics.count('functional_ok');
  }

  // ── Recovery ──────────────────────────────────────────────────────────

  /// A recovery starts. [failedAt] is when the failure began; [protocol] is
  /// the transport being left (null: not a switch, a plain reconnect);
  /// [detectMs]: how long the failure took to be noticed (null: unknown).
  /// While a recovery is already open this does nothing: the open one keeps
  /// its start. `recoveries` / `protocol_switches` are counted when the
  /// recovery ends (ok or failed), so a recovery that is started twice or
  /// never finished (the process died) cannot inflate them.
  void beginRecovery({
    required DateTime failedAt,
    String? protocol,
    String? nodeId,
    String? failedProtocol,
    int? detectMs,
    bool spare = false,
  }) {
    if (recoveryOpen) return;
    if (detectMs != null) metrics.observe('detection_ms', detectMs);
    _recoveryAt = failedAt;
    _recoveryFrom = protocol;
    _recoveryNode = nodeId;
    _recoveryProtocol = failedProtocol ?? protocol;
    _recoveryDetectMs = detectMs;
    _recoverySpare = spare;
  }

  void endRecovery({required bool ok, String? newProtocol, String? reason}) {
    final at = _recoveryAt;
    if (at == null) return;
    final now = _clock();
    final from = _recoveryFrom;
    final ms = now.difference(at).inMilliseconds;
    _recoveryAt = null;
    _recoveryFrom = null;
    metrics.count('recoveries');
    if (from != null) metrics.count('protocol_switches');
    var flap = false;
    final switched = ok && from != null && newProtocol != null && newProtocol != from;
    if (switched) {
      flap = ColituMetricsRules.isFlap(_lastSwitch, from, newProtocol, now);
      _lastSwitch = (from: from, to: newProtocol, at: now);
    }
    if (_nodeOk(_recoveryNode)) {
      _record(
        ColituAcEvents.recovery(
          nodeId: _recoveryNode,
          protocol: _recoveryProtocol,
          toProtocol: ok ? newProtocol : null,
          ok: ok,
          code: reason,
          ms: ms,
          detectMs: _recoveryDetectMs,
          spare: _recoverySpare,
        ),
      );
    }
    if (from != null) {
      _record(
        ColituAcEvents.switched(
          from: from,
          to: ok ? newProtocol : null,
          ok: switched,
          flap: flap,
        ),
      );
    }
    if (!ok) return;
    metrics.count('recovery_successes');
    metrics.observe('recovery_ms', ms);
    if (switched) {
      metrics.count('protocol_switch_successes');
      if (flap) metrics.count('flaps');
    }
  }

  /// Drops the open recovery without an outcome; nothing was counted yet.
  void abandonRecovery() {
    _recoveryAt = null;
    _recoveryFrom = null;
  }

  // ── Drops, probes, choices ────────────────────────────────────────────

  /// The tunnel stopped by itself. The cause is not known (iOS tells only
  /// that the extension stopped), so the reason is `other`, or `no_network`
  /// when [noNetwork].
  ///
  /// Returns the node and protocol that were up, for the recovery event.
  ({String? node, String? protocol}) unexpectedDrop({bool noNetwork = false}) {
    metrics.count('unexpected_disconnects');
    final node = _upNode;
    final proto = _upProtocol;
    final since = _upAt;
    _upNode = _upProtocol = _upAt = null;
    if (since != null && _nodeOk(node)) {
      _record(
        ColituAcEvents.drop(
          nodeId: node,
          protocol: proto,
          code: noNetwork ? 'no_network' : 'other',
          minutes: _clock().difference(since).inMinutes,
        ),
      );
    }
    return (node: node, protocol: proto);
  }

  /// The connection ended on purpose: the next drop is not this one.
  void clearLive() {
    _upNode = _upProtocol = _upAt = null;
  }

  /// A latency measurement of a node ([ms] null: no answer).
  void probe(String nodeId, int? ms) => _record(ColituAcEvents.probe(nodeId, ms));

  /// Automatic mode picked [chosenId]; [candidates] are the fresh pings of
  /// the nodes it chose from.
  void choice(String chosenId, Map<String, int?> candidates) =>
      _record(ColituAcEvents.choice(chosenId, candidates));

  /// The features in use while a connection is up (names only).
  void features(Iterable<String> names) => metrics.features(names);

  /// Sends what is due: the events (hourly) and the counters (every 6 h).
  Future<void> sendDue({required bool killSwitch}) async {
    await events.maybeSend();
    await metrics.maybeSend(killSwitch: killSwitch);
  }
}
