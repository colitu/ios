import 'dart:convert';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';

/// Adaptive Connect v2: which server the automatic mode tries first, and
/// what the app remembers per network about servers and transports.
///
/// A server can answer the latency probe and still carry no VPN traffic
/// (Russian LTE), so a ping is only a hint; what really worked (or failed)
/// on this network decides. Everything here is pure and unit tested.

/// `"<link>|<client_network>"`: the OS link kind (wifi, cellular, ethernet,
/// other) and the panel's opaque key of the user's ISP network. Memory from
/// another key is not applied.
String colituNetworkKey(String link, String clientNetwork) =>
    '$link|$clientNetwork';

/// Link kind from each interface's name and, per address, whether it is
/// loopback or link-local (the same plain data as
/// `ColituStallWatch.physicalNetworkIn`). On iOS `en0` is Wi-Fi, `pdp_ip*`
/// is cellular and other `en*` interfaces are wired adapters. Wi-Fi wins
/// because cellular usually stays up next to it.
String colituLinkKind(Iterable<(String, List<bool>)> interfaces) {
  bool routable(List<bool> local) => local.any((isLocal) => !isLocal);
  var cellular = false;
  var ethernet = false;
  for (final (name, local) in interfaces) {
    if (!routable(local)) continue;
    if (name == 'en0') return 'wifi';
    if (name.startsWith('pdp_ip')) cellular = true;
    if (name.startsWith('en')) ethernet = true;
  }
  if (cellular) return 'cellular';
  if (ethernet) return 'ethernet';
  return 'other';
}

/// One latency probe of a server: the time in ms, or null when the probe
/// timed out or the address was unreachable, with when and on which network
/// it was measured.
class ColituPing {
  const ColituPing({required this.ms, required this.at, required this.network});

  /// A ping counts for the ranking this long, on the network it was taken on.
  static const freshFor = Duration(minutes: 10);

  final int? ms;
  final DateTime at;
  final String network;

  bool get failed => ms == null;

  bool isFresh(String currentNetwork, DateTime now) {
    if (network != currentNetwork) return false;
    final age = now.difference(at);
    // A clock that went backwards makes the age negative: not fresh.
    return !age.isNegative && age < freshFor;
  }

  Map<String, dynamic> toJson() => {
    'ms': ms,
    'at': at.millisecondsSinceEpoch,
    'net': network,
  };

  /// Reads one stored ping; a bare number is the older format (no time, no
  /// network) and is kept for display only.
  static ColituPing? fromJson(Object? value) {
    if (value is num) {
      return ColituPing(
        ms: value.toInt(),
        at: DateTime.fromMillisecondsSinceEpoch(0),
        network: '',
      );
    }
    if (value is! Map) return null;
    final at = value['at'];
    final ms = value['ms'];
    return ColituPing(
      ms: ms is num ? ms.toInt() : null,
      at: DateTime.fromMillisecondsSinceEpoch(at is num ? at.toInt() : 0),
      network: value['net'] is String ? value['net'] as String : '',
    );
  }

  static Map<String, ColituPing> decodeAll(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && fromJson(entry.value) != null)
            entry.key as String: fromJson(entry.value)!,
      };
    } catch (_) {
      return {};
    }
  }

  static String encodeAll(Map<String, ColituPing> pings) => jsonEncode({
    for (final entry in pings.entries) entry.key: entry.value.toJson(),
  });
}

/// `stalledShort`: a stall mark from a failing round or a mid-session stall
/// (10 min); it becomes `stalled` (6 h) once another transport carries
/// traffic on the same network.
enum _Kind { lastServer, lastTransport, stalled, penalized, stalledShort }

class _Entry {
  const _Entry(this.kind, this.network, this.server, this.protocol, this.at);

  final _Kind kind;
  final String network;

  /// Empty for a whole-network entry.
  final String server;
  final String protocol;
  final DateTime at;

  String get key => jsonEncode([kind.index, network, server, protocol]);

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'n': network,
    if (server.isNotEmpty) 's': server,
    if (protocol.isNotEmpty) 'p': protocol,
    't': at.millisecondsSinceEpoch,
  };

  static _Entry? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = _Kind.values.where((k) => k.name == value['k']).firstOrNull;
    final network = value['n'];
    final at = value['t'];
    if (kind == null || network is! String || at is! num) return null;
    final server = value['s'];
    final protocol = value['p'];
    return _Entry(
      kind,
      network,
      server is String ? server : '',
      protocol is String ? protocol : '',
      DateTime.fromMillisecondsSinceEpoch(at.toInt()),
    );
  }
}

/// Per-network memory. Every entry carries the time it was written and is
/// ignored (and pruned) once older than its kind allows.
class ColituAdaptiveMemory {
  ColituAdaptiveMemory({this.cap = 200});

  static const lastGoodServerFor = Duration(hours: 24);
  static const lastGoodTransportFor = Duration(hours: 24);
  static const stalledFor = Duration(hours: 6);
  static const stalledShortFor = Duration(minutes: 10);
  static const penaltyFor = Duration(minutes: 30);

  /// Most entries kept; the oldest go first.
  final int cap;

  final Map<String, _Entry> _entries = {};

  int get length => _entries.length;

  static Duration _lifetime(_Kind kind) => switch (kind) {
    _Kind.lastServer => lastGoodServerFor,
    _Kind.lastTransport => lastGoodTransportFor,
    _Kind.stalled => stalledFor,
    _Kind.stalledShort => stalledShortFor,
    _Kind.penalized => penaltyFor,
  };

  static bool _alive(_Entry entry, DateTime now) {
    final age = now.difference(entry.at);
    return !age.isNegative && age < _lifetime(entry.kind);
  }

  _Entry? _find(
    _Kind kind,
    String network, {
    String server = '',
    String protocol = '',
    required DateTime now,
  }) {
    final entry = _entries[_Entry(kind, network, server, protocol, now).key];
    return entry != null && _alive(entry, now) ? entry : null;
  }

  void _put(_Entry entry) {
    _entries.remove(entry.key);
    _entries[entry.key] = entry;
    if (_entries.length > cap) _trim();
  }

  void _trim() {
    final sorted = _entries.values.toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    for (final entry in sorted.take(_entries.length - cap)) {
      _entries.remove(entry.key);
    }
  }

  /// The server that last carried traffic on [network].
  String? lastGoodServer(String network, DateTime now) {
    _Entry? newest;
    for (final entry in _entries.values) {
      if (entry.kind != _Kind.lastServer || entry.network != network) continue;
      if (!_alive(entry, now)) continue;
      if (newest == null || entry.at.isAfter(newest.at)) newest = entry;
    }
    return newest?.server;
  }

  /// The transport that last carried traffic to [server] on [network].
  String? lastGoodTransport(String network, String server, DateTime now) {
    _Entry? newest;
    for (final entry in _entries.values) {
      if (entry.kind != _Kind.lastTransport ||
          entry.network != network ||
          entry.server != server ||
          !_alive(entry, now)) {
        continue;
      }
      if (newest == null || entry.at.isAfter(newest.at)) newest = entry;
    }
    return newest?.protocol;
  }

  /// Traffic flowed through [server] on [protocol]: it becomes the last-good
  /// server and transport, and what said otherwise is forgotten.
  void recordSuccess(
    String network,
    String server,
    String? protocol,
    DateTime now,
  ) {
    // Another transport carries traffic here: the short stall marks of the
    // others on this network were real, they now last 6 h.
    final promoted = [
      for (final e in _entries.values)
        if (e.kind == _Kind.stalledShort &&
            e.network == network &&
            e.protocol != protocol &&
            _alive(e, now))
          e,
    ];
    _entries.removeWhere(
      (_, e) =>
          e.network == network &&
          ((e.kind == _Kind.lastServer) ||
              (e.kind == _Kind.penalized && e.server == server) ||
              (e.kind == _Kind.lastTransport && e.server == server) ||
              (e.kind == _Kind.stalledShort) ||
              (e.kind == _Kind.stalled &&
                  e.protocol == protocol &&
                  (e.server == server || e.server.isEmpty))),
    );
    for (final e in promoted) {
      _put(_Entry(_Kind.stalled, network, e.server, e.protocol, now));
    }
    _put(_Entry(_Kind.lastServer, network, server, '', now));
    if (protocol != null && protocol.isNotEmpty) {
      _put(_Entry(_Kind.lastTransport, network, server, protocol, now));
    }
  }

  /// [protocol] carried traffic on [network] (to any server) within the
  /// last-good lifetime (24 h).
  bool workedRecently(String network, String protocol, DateTime now) =>
      _entries.values.any(
        (e) =>
            e.kind == _Kind.lastTransport &&
            e.network == network &&
            e.protocol == protocol &&
            _alive(e, now),
      );

  /// Protocols that carried traffic on [network] in the last 24 h, on any
  /// server ("proven").
  Set<String> provenTransports(String network, DateTime now) => {
    for (final e in _entries.values)
      if (e.kind == _Kind.lastTransport && e.network == network && _alive(e, now))
        e.protocol,
  };

  static bool _isStall(_Kind kind) =>
      kind == _Kind.stalled || kind == _Kind.stalledShort;

  /// [protocol] came up on [server] but carried no traffic. Stalled on a
  /// second server of the same network, it counts for the whole network.
  /// A [tentative] mark (a failing round, a mid-session stall) lasts
  /// 10 min until another transport carries traffic here (then 6 h).
  void markStalled(
    String network,
    String server,
    String protocol,
    DateTime now, {
    bool tentative = true,
  }) {
    if (protocol.isEmpty) return;
    final kind = tentative ? _Kind.stalledShort : _Kind.stalled;
    final elsewhere = _entries.values.any(
      (e) =>
          _isStall(e.kind) &&
          e.network == network &&
          e.protocol == protocol &&
          e.server.isNotEmpty &&
          e.server != server &&
          _alive(e, now),
    );
    _put(_Entry(kind, network, server, protocol, now));
    if (elsewhere) _put(_Entry(kind, network, '', protocol, now));
  }

  /// Transports that stalled on [network], to [server] or to any server.
  Set<String> stalledTransports(String network, String server, DateTime now) => {
    for (final entry in _entries.values)
      if (_isStall(entry.kind) &&
          entry.network == network &&
          (entry.server.isEmpty || entry.server == server) &&
          _alive(entry, now))
        entry.protocol,
  };

  /// Every transport of [server] failed on [network].
  void penalize(String network, String server, DateTime now) =>
      _put(_Entry(_Kind.penalized, network, server, '', now));

  bool isPenalized(String network, String server, DateTime now) =>
      _find(_Kind.penalized, network, server: server, now: now) != null;

  /// Drops expired entries and keeps at most [cap].
  void prune(DateTime now) {
    _entries.removeWhere((_, entry) => !_alive(entry, now));
    if (_entries.length > cap) _trim();
  }

  String encode() => jsonEncode([
    for (final entry in _entries.values) entry.toJson(),
  ]);

  /// Reads the stored memory, pruned; anything unreadable starts empty.
  static ColituAdaptiveMemory decode(String? raw, DateTime now, {int cap = 200}) {
    final memory = ColituAdaptiveMemory(cap: cap);
    if (raw == null || raw.isEmpty) return memory;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final value in decoded) {
          final entry = _Entry.fromJson(value);
          if (entry != null) memory._entries[entry.key] = entry;
        }
      }
    } catch (_) {
      return ColituAdaptiveMemory(cap: cap);
    }
    memory.prune(now);
    return memory;
  }
}

/// The panel's network hints: protocols that fail for most users on the
/// user's ISP network (or country), with the anonymous token that lets this
/// device's protocol observations count for that network. Kept from the
/// last server list fetched with the VPN off, for the `client_network` it
/// came with.
class ColituNetworkHints {
  const ColituNetworkHints({
    required this.clientNetwork,
    this.token = '',
    this.blocked = const {},
    this.scope = '',
  });

  static const none = ColituNetworkHints(clientNetwork: '');

  final String clientNetwork;
  final String token;
  final Set<String> blocked;

  /// "network" or "country".
  final String scope;

  /// The token for observations made while on [currentClientNetwork].
  String? tokenFor(String currentClientNetwork) =>
      token.isNotEmpty &&
          clientNetwork.isNotEmpty &&
          clientNetwork == currentClientNetwork
      ? token
      : null;

  /// Hinted-blocked protocols that go last on [network] (whose ISP part is
  /// [currentClientNetwork]): those the hints name, unless the per-network
  /// memory says they carried traffic here in the last 24 h (local
  /// experience beats the hint).
  Set<String> demoted({
    required String currentClientNetwork,
    required String network,
    required ColituAdaptiveMemory memory,
    required DateTime now,
  }) {
    if (clientNetwork.isEmpty || clientNetwork != currentClientNetwork) {
      return const {};
    }
    return {
      for (final protocol in blocked)
        if (!memory.workedRecently(network, protocol, now)) protocol,
    };
  }

  /// From the `/servers` body; null when the body says nothing about the
  /// network (VPN on, older panel), so the stored hints stay.
  static ColituNetworkHints? fromServers(Object? json, String clientNetwork) {
    if (clientNetwork.isEmpty || json is! Map) return null;
    final hints = json['network_hints'];
    final blocked = hints is Map && hints['blocked'] is List
        ? {
            for (final value in hints['blocked'] as List)
              if (value is String && value.trim().isNotEmpty)
                value.trim().toLowerCase(),
          }
        : <String>{};
    final token = json['network_token'];
    return ColituNetworkHints(
      clientNetwork: clientNetwork,
      token: token is String ? token.trim() : '',
      blocked: blocked,
      scope: hints is Map && hints['scope'] is String
          ? hints['scope'] as String
          : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'network': clientNetwork,
    'token': token,
    'blocked': blocked.toList(),
    'scope': scope,
  };

  static ColituNetworkHints decode(String? raw) {
    if (raw == null || raw.isEmpty) return none;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return none;
      return ColituNetworkHints(
        clientNetwork: json['network'] is String ? json['network'] as String : '',
        token: json['token'] is String ? json['token'] as String : '',
        blocked: {
          if (json['blocked'] is List)
            for (final value in json['blocked'] as List)
              if (value is String) value,
        },
        scope: json['scope'] is String ? json['scope'] as String : '',
      );
    } catch (_) {
      return none;
    }
  }
}

/// Stall marks can never lock a network: when the marks would leave at
/// most one of the [offered] transports, they are ignored for this round
/// ([soft]: tried after the unmarked ones instead of last). Otherwise they
/// are [hard] (last).
({Set<String> hard, Set<String> soft}) colituStallMarks(
  Iterable<String> offered,
  Set<String> marks,
) {
  final all = offered.toSet();
  final marked = marks.intersection(all);
  if (marked.isNotEmpty && all.length - marked.length <= 1) {
    return (hard: <String>{}, soft: marked);
  }
  return (hard: marked, soft: <String>{});
}

/// Order in which the automatic mode tries servers. [servers] come in panel
/// order (best-first for this user); multihop routes and servers that
/// cannot be selected are left out.
///
/// 1. penalized on this network: last
/// 2. fresh failed ping: after everything else but the penalized
/// 3. in the user's own country ([clientCountry]): after the foreign ones
/// 4. the last-good server on this network: first
/// 5. fresh successful pings, fastest first
/// 6. no fresh ping: panel order, after the pinged ones
///
/// The "Recommended" entry and the "Fastest server" connect target are both
/// the first element, so the screen never disagrees with what connect does.
List<VPNServer> rankServers(
  Iterable<VPNServer> servers, {
  required Map<String, ColituPing> pings,
  required ColituAdaptiveMemory memory,
  required String network,
  String? clientCountry,
  required DateTime now,
}) {
  final home = (clientCountry ?? '').trim().toUpperCase();
  final lastGood = memory.lastGoodServer(network, now);
  final rows = <({VPNServer server, int bucket, bool last, int? ms, int index})>[];
  var index = 0;
  for (final server in servers) {
    if (server.isMultihop || !server.isSelectable) continue;
    final key = server.selectionKey;
    final ping = pings[key];
    final fresh = ping != null && ping.isFresh(network, now) ? ping : null;
    final int bucket;
    if (memory.isPenalized(network, key, now)) {
      bucket = 3;
    } else if (fresh != null && fresh.failed) {
      bucket = 2;
    } else if (home.isNotEmpty && server.countryCode == home) {
      bucket = 1;
    } else {
      bucket = 0;
    }
    rows.add((
      server: server,
      bucket: bucket,
      last: lastGood != null && lastGood == key,
      ms: fresh?.ms,
      index: index++,
    ));
  }
  rows.sort((a, b) {
    if (a.bucket != b.bucket) return a.bucket.compareTo(b.bucket);
    if (a.last != b.last) return a.last ? -1 : 1;
    final am = a.ms;
    final bm = b.ms;
    if (am != null && bm != null && am != bm) return am.compareTo(bm);
    if ((am == null) != (bm == null)) return am != null ? -1 : 1;
    return a.index.compareTo(b.index);
  });
  return [for (final row in rows) row.server];
}
