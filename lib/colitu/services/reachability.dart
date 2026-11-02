import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/server_latency.dart';

/// Adaptive Connect 4, phase 1 ("honest server list"): which servers the
/// list and the automatic choice may show. Pure logic (no UI, no sockets)
/// so it can be tested; the Windows app has the same rules.
///
/// * Only rounds measured with the VPN off decide reachability. A server is
///   unreachable after [failedRoundsToHide] consecutive failed rounds (each
///   round already retries once) and reachable again after one successful
///   measurement.
/// * Safeguards: a round in which every server, or half of them or more,
///   failed says the network is the problem: its failures do not count, and
///   while the last such round stands nothing is hidden. Nothing is hidden
///   either when half of the known servers or more would be. The servers in
///   `keep` (connected, being connected to, picked) are never hidden.
/// * Nothing measured with the VPN on hides a server.
class ServerReachability {
  static const failedRoundsToHide = 2;

  final Map<String, int> _failedRounds = {};
  bool _networkSuspect = false;

  /// Records one ping round. [results]: every server the round actually
  /// dialled, with its best ping or null when it failed (servers not dialled
  /// are left out). Only a round measured with the VPN off ([vpnOff]) counts.
  void recordRound(Map<String, int?> results, {required bool vpnOff}) {
    if (!vpnOff || results.isEmpty) return;
    final failed = results.values.where((ms) => ms == null || ms <= 0).length;
    final suspect = failed * 2 >= results.length;
    for (final entry in results.entries) {
      if (entry.key.isEmpty) continue;
      final ms = entry.value;
      if (ms != null && ms > 0) {
        _failedRounds.remove(entry.key);
      } else if (!suspect) {
        _failedRounds[entry.key] = (_failedRounds[entry.key] ?? 0) + 1;
      }
    }
    _networkSuspect = suspect;
  }

  /// The server failed [failedRoundsToHide] VPN-off rounds in a row (before
  /// the safeguards).
  bool isUnreachable(String? id) =>
      id != null && (_failedRounds[id] ?? 0) >= failedRoundsToHide;

  /// Ids among [ids] to hide, after the safeguards; never one of [keep].
  Set<String> hidden(Iterable<String?> ids, {Iterable<String?> keep = const []}) {
    final all = {
      for (final id in ids)
        if (id != null && id.isNotEmpty) id,
    };
    if (_networkSuspect || all.isEmpty) return {};
    final unreachable = all.where(isUnreachable).toSet();
    // Half of the servers or more: the network is the problem.
    if (unreachable.length * 2 >= all.length) return {};
    return unreachable.difference({...keep.nonNulls});
  }

  /// [items] without the hidden ones, in the same order.
  List<T> visible<T>(
    List<T> items,
    String? Function(T item) id, {
    Iterable<String?> keep = const [],
  }) {
    final gone = hidden(items.map(id), keep: keep);
    if (gone.isEmpty) return List<T>.of(items);
    return [
      for (final item in items)
        if (!gone.contains(id(item))) item,
    ];
  }

  /// Ids that would be hidden whatever `keep` says: a server that stays in
  /// the list only because it is a favourite or picked is drawn dimmed.
  Set<String> dimmed(Iterable<String?> ids) => hidden(ids);

  /// A server not measurable outside the tunnel keeps its last VPN-off ping
  /// (at most [ServerLatency.shownFor] old, same network) instead of a dash:
  /// [fresh] is the outside reading just taken, [previous] what was stored.
  /// Returns the ping to store.
  static ColituPing carryOver(
    ColituPing fresh,
    ColituPing? previous, {
    required DateTime now,
  }) {
    if (fresh.ms != null || fresh.vpnOff) return fresh;
    if (previous == null || !previous.vpnOff || previous.ms == null) {
      return fresh;
    }
    if (previous.network != fresh.network) return fresh;
    final age = now.difference(previous.at);
    if (age.isNegative || age >= ServerLatency.shownFor) return fresh;
    return previous;
  }

  void clear() {
    _failedRounds.clear();
    _networkSuspect = false;
  }
}
