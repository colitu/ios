import 'dart:convert';

import 'package:colitu_vpn/colitu/services/engine_journal.dart';
import 'package:colitu_vpn/colitu/services/log_redaction.dart';
import 'package:colitu_vpn/colitu/services/site_redaction.dart';

/// The `engine` field of the silent support report (AC4 phase 4, schema
/// `DiagnosticsEngine`): the engine journal split into decisions (with the
/// connection outcomes), ping rounds, hidden servers and whitelist checks,
/// plus the model version and the flags. Newest first; the panel's limits
/// are kept on the device (300 / 60 / 200 / 100 items, 64 flags, an item at
/// most 4 KiB, the whole at most 192 KiB, the oldest decisions dropped
/// first). Every string is masked like the report: secrets redacted, sites
/// and foreign addresses masked, Colitu's own hosts readable.
abstract final class ColituDiagnosticsEngine {
  static const maxDecisions = 300;
  static const maxPingRounds = 60;
  static const maxHiddenServers = 200;
  static const maxWhitelistChecks = 100;
  static const maxFlags = 64;
  static const maxItemBytes = 4 * 1024;
  static const maxTotalBytes = 192 * 1024;
  static const maxModelVersion = 64;

  static int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;

  /// Masks every string in a JSON value (keys stay: they are field names).
  static Object? mask(Object? value, Iterable<String> knownHosts) {
    if (value is String) {
      return SiteRedaction.mask(LogRedaction.redact(value), knownHosts: knownHosts);
    }
    if (value is List) return [for (final item in value) mask(item, knownHosts)];
    if (value is Map) {
      return {
        for (final entry in value.entries) '${entry.key}': mask(entry.value, knownHosts),
      };
    }
    return value;
  }

  /// [item] within [maxItemBytes]: a decision too large keeps its best
  /// ranked candidates (the rest are counted in `candidates_trimmed`);
  /// anything else too large is dropped (null).
  static Map<String, dynamic>? _fit(Map<String, dynamic> item) {
    if (_bytes(item) <= maxItemBytes) return item;
    final candidates = item['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final ranking = item['ranking'];
      final order = <int>[
        if (ranking is List)
          for (final i in ranking)
            if (i is int && i >= 0 && i < candidates.length) i,
      ];
      for (var i = 0; i < candidates.length; i++) {
        if (!order.contains(i)) order.add(i);
      }
      var keep = order.length;
      while (keep > 0) {
        keep = keep > 8 ? keep ~/ 2 : keep - 1;
        final trimmed = {
          ...item,
          'candidates': [
            for (final i in order.take(keep))
              {
                'index': i,
                if (candidates[i] is Map)
                  ...(candidates[i] as Map).cast<String, dynamic>(),
              },
          ],
          'candidates_trimmed': candidates.length - keep,
        };
        if (_bytes(trimmed) <= maxItemBytes) return trimmed;
      }
      final bare = {...item, 'candidates': const [], 'candidates_trimmed': candidates.length};
      if (_bytes(bare) <= maxItemBytes) return bare;
    }
    return null;
  }

  static Map<String, dynamic> _item(ColituEngineJournalEntry entry) => {
    'at': entry.at.toUtc().toIso8601String(),
    'kind': entry.kind,
    if (entry.data is Map) ...(entry.data as Map).cast<String, dynamic>() else 'data': ?entry.data,
  };

  /// The `engine` object. [journal] oldest first (as
  /// [ColituEngineJournal.snapshot] gives it); [hiddenNow]: the servers the
  /// honest list hides at this moment.
  static Map<String, dynamic> build({
    required List<ColituEngineJournalEntry> journal,
    String? modelVersion,
    Map<String, Object?> flags = const {},
    Iterable<String> hiddenNow = const [],
    Iterable<String> knownHosts = const [],
    DateTime? now,
  }) {
    final hosts = knownHosts.toList();
    final decisions = <Map<String, dynamic>>[];
    final pingRounds = <Map<String, dynamic>>[];
    final hidden = <Map<String, dynamic>>[];
    final whitelist = <Map<String, dynamic>>[];
    final at = (now ?? DateTime.now()).toUtc().toIso8601String();
    for (final id in hiddenNow) {
      hidden.add({'at': at, 'node_id': id, 'reason': 'hidden_now'});
    }
    // Newest first.
    for (final entry in journal.reversed) {
      final item = mask(_item(entry), hosts) as Map<String, dynamic>;
      switch (entry.kind) {
        case ColituEngineJournal.decision || ColituEngineJournal.outcome:
          if (decisions.length >= maxDecisions) continue;
          final fitted = _fit(item);
          if (fitted != null) decisions.add(fitted);
        case ColituEngineJournal.pingRound:
          if (pingRounds.length < maxPingRounds && _bytes(item) <= maxItemBytes) {
            pingRounds.add(item);
          }
        case ColituEngineJournal.hidden:
          final servers = item['servers'];
          for (final id in servers is List ? servers : const []) {
            if (hidden.length >= maxHiddenServers) break;
            hidden.add({
              'at': item['at'],
              'node_id': '$id',
              'reason': item['reason'] ?? 'hidden',
              'of': ?item['of'],
            });
          }
        case ColituEngineJournal.whitelist:
          if (whitelist.length < maxWhitelistChecks && _bytes(item) <= maxItemBytes) {
            whitelist.add(item);
          }
      }
    }
    final keptFlags = <String, Object?>{};
    for (final entry in flags.entries) {
      if (keptFlags.length >= maxFlags) break;
      final value = entry.value;
      keptFlags[entry.key] = value is String ? mask(value, hosts) : value;
    }
    final version = modelVersion == null
        ? null
        : (modelVersion.length > maxModelVersion
              ? modelVersion.substring(0, maxModelVersion)
              : modelVersion);
    final engine = <String, dynamic>{
      'model_version': ?version,
      'flags': keptFlags,
      'decisions': decisions,
      'ping_rounds': pingRounds,
      'hidden_servers': hidden.take(maxHiddenServers).toList(),
      'whitelist_checks': whitelist,
    };
    // The whole within the limit: the oldest decisions go first, then the
    // oldest of the other lists.
    if (_bytes(engine) > maxTotalBytes) {
      for (final key in ['decisions', 'ping_rounds', 'hidden_servers', 'whitelist_checks']) {
        final list = engine[key] as List;
        while (list.isNotEmpty && _bytes(engine) > maxTotalBytes) {
          // Dropping one at a time is slow for big lists: estimate a batch.
          final over = _bytes(engine) - maxTotalBytes;
          final each = (_bytes(list) / list.length).ceil().clamp(1, maxItemBytes);
          final drop = (over / each).ceil().clamp(1, list.length);
          list.removeRange(list.length - drop, list.length);
        }
        if (_bytes(engine) <= maxTotalBytes) break;
      }
    }
    return engine;
  }
}
