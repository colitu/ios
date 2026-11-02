import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/server_names.dart';
import 'package:colitu_vpn/colitu/services/colitu_lm.dart';
import 'package:colitu_vpn/colitu/services/server_latency.dart';
import 'package:crypto/crypto.dart';

/// The panel's Adaptive Connect 4 switch for this device
/// (`features.ac_engine_4` of `/servers`). Off (the default), automatic mode
/// keeps the AC 3 rules unchanged and whitelist mode never starts. The last
/// value is stored and holds while the panel cannot be reached.
abstract final class ColituAc4Switch {
  static bool _remote = false;

  static bool get enabled => _remote;

  static void setRemote(bool on) => _remote = on;

  /// `features.ac_engine_4` of a `/servers` body; null when absent (an older
  /// panel: the stored value stays) or not a boolean.
  static bool? parse(Object? json) {
    if (json is! Map) return null;
    final features = json['features'];
    if (features is! Map) return null;
    final value = features['ac_engine_4'];
    return value is bool ? value : null;
  }
}

/// Adaptive Connect 4 around the model ([ColituLm]): the candidates built
/// from the server list and the server order a decision gives. Pure logic.
abstract final class ColituLmPlanner {
  /// The name ends in the bridge suffix ("Finlandiya (Köprü)", "… (Мост)",
  /// "… (Bridge)"): a node whose entry address is in Russia and whose
  /// traffic leaves abroad (its country is the exit's).
  static bool isBridgeName(String? raw) {
    final match = RegExp(r'^(.*?)\s*\(([^()]*)\)$').firstMatch(raw?.trim() ?? '');
    if (match == null) return false;
    final suffix = ColituServerNames.normalize(match.group(2) ?? '');
    return const ['мост', 'kopru', 'bridge'].contains(suffix);
  }

  static String _upper(String? value) => (value ?? '').trim().toUpperCase();

  /// Entry and exit country of a list entry. A multihop route: its two ends.
  /// A bridge node ("Finlandiya (Köprü)"): its entry address is in Russia,
  /// its country is the exit's. Anything else: its own country twice. Upper
  /// case; empty when unknown.
  static (String, String) countries(VPNServer server) {
    final own = _upper(server.countryCode);
    if (server.isMultihop) {
      final exit = _upper(server.exit?.country);
      return (_upper(server.entry?.country), exit.isNotEmpty ? exit : own);
    }
    if (own != 'RU' &&
        own.isNotEmpty &&
        (isBridgeName(server.name) || isBridgeName(server.displayName))) {
      return ('RU', own);
    }
    return (own, own);
  }

  /// A bridge (shared rule, all apps): a server whose name ends in
  /// "(Köprü)", "(Мост)" or "(Bridge)", or a multihop route whose entry
  /// country is the device's network country ([networkCountry]).
  static bool isBridge(VPNServer server, {String? networkCountry}) {
    if (server.isMultihop) {
      final entry = _upper(server.entry?.country);
      return entry.isNotEmpty && entry == _upper(networkCountry);
    }
    return isBridgeName(server.name) || isBridgeName(server.displayName);
  }

  /// Its traffic leaves in Russia (a plain RU server, or a route exiting
  /// there): never chosen automatically.
  static bool exitsInRussia(VPNServer server) => countries(server).$2 == 'RU';

  static bool _usable(VPNServer server) =>
      server.id.trim().isNotEmpty &&
      !server.isMultihop &&
      server.available &&
      !server.locked &&
      !server.alpha;

  /// The model's candidates: every usable server × each protocol it lists
  /// (one candidate with no protocol when it lists none, which uses the
  /// server-level prior). Multihop routes are left out: automatic mode does
  /// not use them.
  static List<({ColituLmCandidate candidate, VPNServer server})> candidates(
    Iterable<VPNServer> servers, {
    required int? Function(VPNServer server) latencyMs,
    Set<String> hintedServers = const {},
    required List<ColituLmOutcome> Function(String nodeId, String protocol) history,
  }) {
    final result = <({ColituLmCandidate candidate, VPNServer server})>[];
    final seen = <String>{};
    final hinted = {for (final key in hintedServers) key.toLowerCase()};
    for (final server in servers) {
      if (!_usable(server) || !seen.add(server.id.toLowerCase())) continue;
      final (entry, exit) = countries(server);
      final isHinted =
          hinted.contains(server.id.toLowerCase()) ||
          hinted.contains(server.selectionKey.toLowerCase());
      final ms = latencyMs(server);
      final protocols = server.protocols.isNotEmpty ? server.protocols : const [''];
      for (final protocol in protocols) {
        result.add((
          candidate: ColituLmCandidate(
            nodeId: server.id,
            protocol: protocol,
            entryCountry: entry,
            exitCountry: exit,
            whitelistOk: server.whitelistOk,
            recommended: server.isRecommended,
            hintBlocked: isHinted,
            load: server.loadLevel,
            latencyMs: ms?.toDouble(),
            history: history(server.id, protocol),
          ),
          server: server,
        ));
      }
    }
    return result;
  }

  /// The servers in the order a decision tries them: the chosen candidate's
  /// server first, then the ranking's servers (each once). `lead` is the
  /// chosen protocol (null when the server lists none).
  static ({List<VPNServer> servers, String? lead}) order(
    ColituLmDecision decision,
    List<({ColituLmCandidate candidate, VPNServer server})> pairs,
  ) {
    final servers = <VPNServer>[];
    final seen = <String>{};
    final choice = decision.choice;
    for (final index in [?choice, ...decision.ranking]) {
      if (index >= 0 &&
          index < pairs.length &&
          seen.add(pairs[index].server.id.toLowerCase())) {
        servers.add(pairs[index].server);
      }
    }
    final lead =
        choice != null &&
            choice >= 0 &&
            choice < pairs.length &&
            pairs[choice].candidate.protocol.isNotEmpty
        ? pairs[choice].candidate.protocol
        : null;
    return (servers: servers, lead: lead);
  }

  /// Whitelist mode while no model is there yet (AC 3 rules): the
  /// whitelist_ok servers only, bridges first, then by ping. Empty when none
  /// is flagged (the usual order then stays).
  static List<VPNServer> whitelistOrder(
    Iterable<VPNServer> servers,
    int? Function(VPNServer server) latencyMs, {
    String? networkCountry,
  }) {
    final rows = <({VPNServer server, int index})>[];
    var index = 0;
    for (final server in servers) {
      if (server.whitelistOk && _usable(server)) {
        rows.add((server: server, index: index++));
      }
    }
    const none = 1 << 40;
    rows.sort((a, b) {
      final ab = isBridge(a.server, networkCountry: networkCountry) ? 0 : 1;
      final bb = isBridge(b.server, networkCountry: networkCountry) ? 0 : 1;
      if (ab != bb) return ab.compareTo(bb);
      final am = latencyMs(a.server) ?? none;
      final bm = latencyMs(b.server) ?? none;
      if (am != bm) return am.compareTo(bm);
      return a.index.compareTo(b.index);
    });
    return [for (final row in rows) row.server];
  }
}

/// Servers located in Russia (owner, 2026-11-02): listed only when the app
/// speaks Russian or the device's network is in Russia. A plain RU server is
/// never chosen automatically (see `autoExcluded` and the model); bridges are
/// not RU servers.
abstract final class ColituRuServers {
  static bool visible(
    VPNServer server, {
    required String? appLanguage,
    required String? networkCountry,
  }) =>
      server.countryCode.trim().toUpperCase() != 'RU' ||
      (appLanguage ?? '').toLowerCase() == 'ru' ||
      (networkCountry ?? '').trim().toUpperCase() == 'RU';
}

/// One stored outcome of [ColituLmHistory].
class ColituLmHistoryEntry {
  const ColituLmHistoryEntry({
    required this.network,
    required this.server,
    required this.protocol,
    required this.at,
    required this.ok,
  });

  final String network;
  final String server;
  final String protocol;

  /// Unix seconds.
  final int at;
  final bool ok;

  Map<String, dynamic> toJson() => {
    'n': network,
    's': server,
    'p': protocol,
    't': at,
    'ok': ok,
  };

  static ColituLmHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final n = json['n'];
    final s = json['s'];
    final p = json['p'];
    final t = json['t'];
    if (n is! String || n.isEmpty || s is! String || s.isEmpty || p is! String || t is! num) {
      return null;
    }
    return ColituLmHistoryEntry(network: n, server: s, protocol: p, at: t.toInt(), ok: json['ok'] == true);
  }
}

/// This device's own outcomes per (network, server, protocol), for the
/// model's own feature and Beta posterior. The network is kept only as a
/// hash of the Adaptive Connect network key; the data stays on the device
/// and is never sent. Old outcomes fade (half-life 72 h) and are dropped
/// after 21 days.
class ColituLmHistory {
  ColituLmHistory({this.save});

  static const maxPerKey = 24;
  static const maxRecords = 3000;
  static const maxAge = Duration(days: 21);

  /// Persists the encoded history; null (tests) keeps it in memory only.
  final void Function(String encoded)? save;
  final _byKey = <String, List<ColituLmHistoryEntry>>{};

  /// Reads [encoded] (as written by [encode]); bad data is ignored.
  void load(String? encoded, DateTime now) {
    _byKey.clear();
    if (encoded == null || encoded.isEmpty) return;
    try {
      final list = jsonDecode(encoded);
      if (list is! List) return;
      for (final item in list) {
        final entry = ColituLmHistoryEntry.fromJson(item);
        if (entry != null) {
          _list(_key(entry.network, entry.server, entry.protocol)).add(entry);
        }
      }
      _prune(now);
    } catch (_) {}
  }

  String encode() => jsonEncode([
    for (final list in _byKey.values) for (final entry in list) entry.toJson(),
  ]);

  /// The network key as stored: 16 hex characters of its SHA-256.
  static String networkHash(String? networkKey) =>
      sha256.convert(utf8.encode(networkKey ?? '')).toString().substring(0, 16);

  static String _key(String networkHash, String server, String protocol) =>
      '$networkHash|${server.trim().toLowerCase()}|${protocol.trim().toLowerCase()}';

  List<ColituLmHistoryEntry> _list(String key) => _byKey.putIfAbsent(key, () => []);

  void record(
    String networkKey,
    String? server,
    String? protocol,
    bool ok,
    DateTime now,
  ) {
    if (server == null || server.trim().isEmpty || protocol == null) return;
    final hash = networkHash(networkKey);
    _list(_key(hash, server, protocol)).add(
      ColituLmHistoryEntry(
        network: hash,
        server: server.trim().toLowerCase(),
        protocol: protocol.trim().toLowerCase(),
        at: now.millisecondsSinceEpoch ~/ 1000,
        ok: ok,
      ),
    );
    _prune(now);
    save?.call(encode());
  }

  /// The outcomes on this network with the server and protocol, ages in
  /// hours.
  List<ColituLmOutcome> outcomes(
    String networkKey,
    String? server,
    String? protocol,
    DateTime now,
  ) {
    if (server == null || server.trim().isEmpty || protocol == null) return const [];
    final list = _byKey[_key(networkHash(networkKey), server, protocol)];
    if (list == null) return const [];
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    return [
      for (final entry in list)
        ColituLmOutcome(
          ageH: (seconds - entry.at < 0 ? 0 : seconds - entry.at) / 3600.0,
          ok: entry.ok,
        ),
    ];
  }

  int get count => _byKey.values.fold(0, (sum, list) => sum + list.length);

  void _prune(DateTime now) {
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final oldest = seconds - maxAge.inSeconds;
    final newest = seconds + 300;
    for (final key in _byKey.keys.toList()) {
      final list = _byKey[key]!;
      list.removeWhere((e) => e.at < oldest || e.at > newest);
      if (list.length > maxPerKey) list.removeRange(0, list.length - maxPerKey);
      if (list.isEmpty) _byKey.remove(key);
    }
    final total = count;
    if (total > maxRecords) {
      // The oldest outcomes go first.
      final times = [for (final list in _byKey.values) for (final e in list) e.at]..sort();
      final cut = times[total - maxRecords];
      for (final key in _byKey.keys.toList()) {
        _byKey[key]!.removeWhere((e) => e.at < cut);
        if (_byKey[key]!.isEmpty) _byKey.remove(key);
      }
    }
  }
}

/// The last `/client/ac-model` answer and when it came. Fresh for 1 h; an
/// older one is still used (offline) while a refetch is tried, at most every
/// 10 minutes. Stored across restarts by the caller ([encode]/[load]).
class ColituLmModelStore {
  static const freshFor = Duration(hours: 1);
  static const retryEvery = Duration(minutes: 10);

  ColituLmModel? model;
  DateTime? fetchedAt;
  DateTime? _lastAttempt;

  /// Hours since the model was fetched; 0 without a model.
  double ageH(DateTime now) {
    final at = fetchedAt;
    if (at == null) return 0;
    final ms = now.difference(at).inMilliseconds;
    return ms < 0 ? 0 : ms / 3600000.0;
  }

  /// A fetch is due: no model, a stale one, or one of another country than
  /// the device's network now; never more often than [retryEvery]. Marks the
  /// attempt when it says yes.
  bool takeFetchSlot(DateTime now, String? country) {
    final at = fetchedAt;
    final current = model;
    final cc = (country ?? '').trim().toUpperCase();
    final modelCountry = (current?.country ?? '').trim().toUpperCase();
    final due =
        current == null ||
        at == null ||
        now.difference(at) >= freshFor ||
        at.isAfter(now.add(const Duration(minutes: 5))) ||
        (cc.length == 2 && modelCountry.length == 2 && cc != modelCountry);
    final last = _lastAttempt;
    if (!due || (last != null && now.difference(last) < retryEvery)) return false;
    _lastAttempt = now;
    return true;
  }

  void set(ColituLmModel value, DateTime now) {
    model = value;
    fetchedAt = now;
  }

  String? encode() {
    final current = model;
    final at = fetchedAt;
    if (current == null || at == null) return null;
    return jsonEncode({
      'fetched_at': at.toUtc().toIso8601String(),
      'model': current.toJson(),
    });
  }

  void load(String? encoded) {
    if (encoded == null || encoded.isEmpty) return;
    try {
      final json = jsonDecode(encoded);
      if (json is! Map) return;
      final parsed = ColituLmModel.fromJson(json['model']);
      final at = DateTime.tryParse('${json['fetched_at']}');
      if (parsed != null && at != null) {
        model = parsed;
        fetchedAt = at;
      }
    } catch (_) {}
  }
}

/// One whitelist check: how many hosts of each set answered on TCP 443, and
/// how long it took.
class ColituWhitelistCheck {
  const ColituWhitelistCheck(
    this.foreignOk,
    this.foreignTotal,
    this.domesticOk,
    this.domesticTotal,
    this.ms,
  );

  final int foreignOk;
  final int foreignTotal;
  final int domesticOk;
  final int domesticTotal;
  final int ms;

  /// The detection rule: foreign ≤ 1 of 5 and domestic ≥ 2 of 4.
  bool get whitelist => ColituWhitelist.isWhitelist(foreignOk, domesticOk);

  /// "on:f1/5:d3/4" as the panel stores it.
  String flag(bool on) =>
      '${on ? 'on' : 'off'}:f$foreignOk/$foreignTotal:d$domesticOk/$domesticTotal';
}

/// Whitelist mode (mobile operators that let only allowed addresses
/// through): detection with the VPN off and after two connection failures in
/// a row, a re-check every 5 minutes while it holds.
abstract final class ColituWhitelist {
  static const foreignMaxOk = 1;
  static const domesticMinOk = 2;
  static const port = 443;
  static const maxHosts = 8;
  static const budget = Duration(seconds: 4);
  static const recheckEvery = Duration(minutes: 5);

  /// Neutral foreign hosts of the foreign set (with two Colitu nodes: five
  /// in all). The same on every platform.
  static const neutralForeignHosts = [
    'www.google.com',
    'www.wikipedia.org',
    'www.cloudflare.com',
  ];

  /// Used while the panel sends no `whitelist_probe` (the panel's default).
  static const defaultProbe = <String, List<String>>{
    'RU': ['ya.ru', 'vk.com', 'gosuslugi.ru', 'mail.ru'],
  };

  static bool isWhitelist(int foreignOk, int domesticOk) =>
      foreignOk <= foreignMaxOk && domesticOk >= domesticMinOk;

  /// The mode after a check: it starts when the rule holds and ends only
  /// when the foreign set works again (nothing answering at all is no
  /// network, not the end of the whitelist).
  static bool nextState(bool current, ColituWhitelistCheck check) =>
      current ? check.foreignOk <= foreignMaxOk : check.whitelist;

  /// `whitelist_probe` of a `/servers` body: country → hosts; bad countries
  /// and host names are dropped (at most 20 countries, 8 hosts each).
  static Map<String, List<String>> parseProbe(Object? raw) {
    final result = <String, List<String>>{};
    if (raw is! Map) return result;
    for (final entry in raw.entries.take(20)) {
      final country = '${entry.key}'.trim().toUpperCase();
      if (!RegExp(r'^[A-Z]{2}$').hasMatch(country) || entry.value is! List) continue;
      final hosts = (entry.value as List)
          .whereType<String>()
          .map((h) => h.trim().toLowerCase())
          .where(validHost)
          .toSet()
          .take(maxHosts)
          .toList();
      if (hosts.isNotEmpty) result[country] = hosts;
    }
    return result;
  }

  static bool validHost(String host) =>
      host.isNotEmpty &&
      host.length <= 253 &&
      host.contains('.') &&
      !host.startsWith('.') &&
      !host.endsWith('.') &&
      !host.startsWith('-') &&
      RegExp(r'^[a-z0-9.\-]+$').hasMatch(host);

  /// The domestic set of [country]: the panel's list, else the default;
  /// empty when none.
  static List<String> domesticSet(Map<String, List<String>>? probe, String? country) {
    final cc = (country ?? '').trim().toUpperCase();
    if (cc.length != 2) return const [];
    final source = probe != null && probe.isNotEmpty ? probe : defaultProbe;
    return (source[cc] ?? const <String>[]).take(maxHosts).toList();
  }

  /// The foreign set: the neutral hosts on TCP 443 plus two Colitu nodes
  /// outside Russia that are not whitelist servers or bridges, each on its
  /// own ping port (host and port of the latency probe), the fastest first.
  static List<({String host, int port})> foreignSet(
    Iterable<VPNServer> servers,
    int? Function(VPNServer server) ping,
  ) {
    final rows = <({String host, int port, int? ms, int index})>[];
    var index = 0;
    for (final server in servers) {
      final host = server.host?.trim() ?? '';
      final serverPort = server.port;
      if (server.isMultihop ||
          server.whitelistOk ||
          host.isEmpty ||
          serverPort == null ||
          !ServerLatency.isAllowedPort(serverPort) ||
          ColituLmPlanner.exitsInRussia(server) ||
          ColituLmPlanner.isBridge(server)) {
        continue;
      }
      rows.add((host: host, port: serverPort, ms: ping(server), index: index++));
    }
    const none = 1 << 40;
    rows.sort((a, b) {
      final am = a.ms ?? none;
      final bm = b.ms ?? none;
      return am != bm ? am.compareTo(bm) : a.index.compareTo(b.index);
    });
    final nodes = <({String host, int port})>[];
    final seen = <String>{};
    for (final row in rows) {
      if (seen.add(row.host.toLowerCase())) {
        nodes.add((host: row.host, port: row.port));
      }
      if (nodes.length == 2) break;
    }
    return [
      for (final host in neutralForeignHosts) (host: host, port: port),
      ...nodes,
    ];
  }

  /// TCP connect to [host]:[port] within [timeout] (public addresses only);
  /// true when it answered.
  static Future<bool> tcpReachable(String host, int port, Duration timeout) async {
    final watch = Stopwatch()..start();
    try {
      final address = await ServerLatency.resolvePublic(host, preferIPv4: true)
          .timeout(timeout);
      if (address == null) return false;
      final left = timeout - watch.elapsed;
      if (left.inMilliseconds <= 50) return false;
      final socket = await Socket.connect(address, port, timeout: left);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// One check: every host of both sets in parallel (the foreign set on its
  /// ports, the domestic set on TCP 443), within [budget]. Run only with the
  /// VPN off (the app cannot keep its sockets outside the tunnel).
  /// [reachable] is swapped in tests.
  static Future<ColituWhitelistCheck> check(
    List<({String host, int port})> foreign,
    List<String> domestic, {
    Future<bool> Function(String host, int port, Duration timeout)? reachable,
  }) async {
    final probe = reachable ?? tcpReachable;
    final watch = Stopwatch()..start();
    Future<bool> one(({String host, int port}) target) async {
      try {
        return await probe(target.host, target.port, budget).timeout(
          budget + const Duration(milliseconds: 200),
          onTimeout: () => false,
        );
      } catch (_) {
        return false;
      }
    }

    final f = foreign.take(10).toList();
    final d = [for (final host in domestic.take(10)) (host: host, port: port)];
    final results = await Future.wait([...f.map(one), ...d.map(one)]);
    final foreignOk = results.take(f.length).where((ok) => ok).length;
    final domesticOk = results.skip(f.length).where((ok) => ok).length;
    final ms = watch.elapsedMilliseconds;
    return ColituWhitelistCheck(
      foreignOk,
      f.length,
      domesticOk,
      d.length,
      ms > 600000 ? 600000 : ms,
    );
  }
}
