import 'dart:async';
import 'dart:convert';

import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';

/// Adaptive Connect 3.0 recovery set: `GET /client/recovery` answers up to 4
/// complete configs (one per country first), valid until `recovery_until`
/// (about 14 days). It is used only when the API cannot be reached at all and
/// there is no regular cached config (see [ColituRecovery.decide]). It grants
/// nothing: the nodes still check the device credential.
class ColituRecoverySet {
  const ColituRecoverySet._({
    required this.raw,
    required this.generatedAt,
    required this.recoveryUntil,
    required this.configs,
  });

  /// The JSON as stored.
  final String raw;
  final DateTime generatedAt;
  final DateTime recoveryUntil;

  /// The envelopes in the panel's order, each like a `/config` answer.
  final List<VPNConfig> configs;

  static const maxConfigs = 4;

  bool expired(DateTime now) => !now.isBefore(recoveryUntil);

  /// From a decoded body or the stored text. Null (rejected) when it is not a
  /// map, `recovery_until` or `generated_at` is missing or not a date, or no
  /// usable envelope is left. A malformed envelope is skipped, not fatal.
  static ColituRecoverySet? parse(Object? json) {
    try {
      final Object? body = json is String ? jsonDecode(json) : json;
      if (body is! Map) return null;
      final until = _date(body['recovery_until']);
      final generated = _date(body['generated_at']);
      final list = body['configs'];
      if (until == null || generated == null || list is! List) return null;
      final configs = <VPNConfig>[];
      final seen = <String>{};
      for (final item in list) {
        if (configs.length == maxConfigs) break;
        if (item is! Map<String, dynamic>) continue;
        try {
          final config = VPNConfig.fromJson(item);
          if (config.serverId.isEmpty ||
              config.isMultihop ||
              config.outboundCandidates.isEmpty ||
              !seen.add(config.serverId)) {
            continue;
          }
          configs.add(config);
        } on FormatException {
          continue;
        }
      }
      if (configs.isEmpty) return null;
      return ColituRecoverySet._(
        raw: json is String ? json : jsonEncode(body),
        generatedAt: generated,
        recoveryUntil: until,
        configs: configs,
      );
    } catch (_) {
      return null;
    }
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

/// What a connect does with the recovery set.
enum ColituRecoveryDecision {
  /// Not applicable: the usual failure handling stays.
  none,

  /// The set is past `recovery_until`: delete it, give up as before.
  expired,

  /// Try its servers.
  use,
}

/// The pure decisions around the recovery set.
abstract final class ColituRecovery {
  static const refreshAfter = Duration(hours: 24);
  static const attemptEvery = Duration(hours: 6);

  /// An API failure at network level: no HTTP answer from any API base. The
  /// failover (`ApiFailoverInterceptor`) tries every base before this error
  /// reaches the caller. A timeout of the whole config call counts too: the
  /// first base did not answer within the connect timeout.
  static bool isNetworkLevel(Object? error) =>
      error is TimeoutException ||
      (error is APIException &&
          error.statusCode == null &&
          error.code == APIErrorCode.networkUnavailable);

  /// Answers that delete the stored set: signed out, device revoked, plan
  /// ended. Network errors and 5xx keep it.
  static bool dropsSet(Object? error) =>
      error is APIException &&
      (error.statusCode == 401 || error.statusCode == 403);

  /// Whether a failed connect may turn to [set]: only in automatic server
  /// mode (not a picked server, not multihop), only when [apiError] is
  /// network-level and the regular cached config cannot connect
  /// ([cacheUsable]; this app has none). An expired set is not used. With
  /// [enabled] false (`kAdaptiveConnect3`; callers pass the flag, the default
  /// is the feature on) the set is never used.
  static ColituRecoveryDecision decide({
    required bool automatic,
    required bool multihop,
    required Object? apiError,
    required bool cacheUsable,
    required ColituRecoverySet? set,
    required DateTime now,
    bool enabled = true,
  }) {
    if (!enabled || !automatic || multihop || cacheUsable || set == null) {
      return ColituRecoveryDecision.none;
    }
    if (!isNetworkLevel(apiError)) return ColituRecoveryDecision.none;
    if (set.expired(now)) return ColituRecoveryDecision.expired;
    return ColituRecoveryDecision.use;
  }

  /// The servers to try, in the set's order, without those that already
  /// failed in this connect ([failed]: node ids).
  static List<VPNConfig> serversToTry(
    ColituRecoverySet set,
    Iterable<String> failed,
  ) {
    final skip = failed.toSet();
    return [
      for (final config in set.configs)
        if (!skip.contains(config.serverId)) config,
    ];
  }

  /// The next server to try, or null when every one failed.
  static VPNConfig? next(ColituRecoverySet set, Iterable<String> failed) =>
      serversToTry(set, failed).firstOrNull;

  /// Fetch in the background: no stored set or one generated more than 24 h
  /// ago, and the last attempt at least 6 h back (a failed attempt counts).
  /// Never with [enabled] false (`kAdaptiveConnect3`).
  static bool refreshDue({
    required DateTime? generatedAt,
    required DateTime? lastAttempt,
    required DateTime now,
    bool enabled = true,
  }) {
    if (!enabled) return false;
    if (lastAttempt != null &&
        !lastAttempt.isAfter(now) &&
        now.difference(lastAttempt) < attemptEvery) {
      return false;
    }
    return generatedAt == null || now.difference(generatedAt) > refreshAfter;
  }
}
