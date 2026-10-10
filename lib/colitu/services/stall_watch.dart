import 'dart:io';

import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';

/// Decides when a live tunnel's primary path has stalled mid-session, on
/// every transport.
///
/// Russian mobile networks throttle long-lived flows: the tunnel stays up
/// but stops carrying traffic, and a call drops. While connected, the
/// controller checks the primary every [interval] for the first
/// [fastPhase] of a session ([startSession]), then every [slowInterval];
/// after [failuresToSwitch] failed checks in a row (with the device still
/// on a network) the primary is dead, at most once per [switchCooldown].
class ColituStallWatch {
  ColituStallWatch({
    this.interval = const Duration(seconds: 5),
    this.slowInterval = const Duration(seconds: 30),
    this.fastPhase = const Duration(seconds: 90),
    this.failuresToSwitch = 3,
    this.switchCooldown = const Duration(seconds: 60),
    this.flowingBytes = 64 * 1024,
  });

  final Duration interval;
  final Duration slowInterval;
  final Duration fastPhase;
  DateTime? _sessionStart;

  /// A connect settled: checks run every [interval] for [fastPhase], then
  /// every [slowInterval].
  void startSession(DateTime now) {
    _sessionStart = now;
    reset(now);
  }

  /// The check period at [now].
  Duration intervalAt(DateTime now) {
    final start = _sessionStart;
    if (start == null || now.difference(start) < fastPhase) return interval;
    return slowInterval;
  }
  final int failuresToSwitch;
  final Duration switchCooldown;

  /// Bytes received through the tunnel within one interval that prove it
  /// carries traffic without an extra check request.
  final int flowingBytes;

  var _failures = 0;
  var _probing = false;
  DateTime? _lastCheck;
  DateTime? _lastSwitch;
  int? _lastDownBytes;

  int get failures => _failures;

  /// A new session (or none): the count and the clock start again. The time
  /// of the last automatic switch is kept, so the cooldown spans sessions.
  void reset(DateTime now) {
    _failures = 0;
    _probing = false;
    _lastCheck = now;
    _lastDownBytes = null;
  }

  /// True when a check is due and none is in flight.
  bool due(DateTime now) {
    if (_probing) return false;
    final last = _lastCheck;
    return last == null || now.difference(last) >= intervalAt(now);
  }

  /// Starts a check. Returns true when the received bytes since the last
  /// check already prove traffic flows; the caller then skips the request
  /// and reports success.
  bool begin(DateTime now, int downBytes) {
    _probing = true;
    _lastCheck = now;
    final previous = _lastDownBytes;
    _lastDownBytes = downBytes;
    return previous != null && downBytes - previous >= flowingBytes;
  }

  /// Records a check's result. Returns true when the transport should be
  /// switched now. A failure without a network is not the transport's fault
  /// and does not count.
  bool finish({
    required bool ok,
    required bool hasNetwork,
    required DateTime now,
    int? threshold,
  }) {
    _probing = false;
    if (ok || !hasNetwork) {
      _failures = 0;
      return false;
    }
    _failures++;
    if (_failures < (threshold ?? failuresToSwitch)) return false;
    final last = _lastSwitch;
    if (last != null && now.difference(last) < switchCooldown) return false;
    _failures = 0;
    _lastSwitch = now;
    return true;
  }

  /// What a round that found the primary dead leads to (spare-aware): with
  /// a warm spare attached and the normal path still working nothing
  /// reconnects (the spare carries the traffic); otherwise reconnect.
  static ColituWatchAction decide({
    required bool primaryDead,
    required bool spareAttached,
    required bool normalOk,
  }) {
    if (!primaryDead) return ColituWatchAction.none;
    if (spareAttached && normalOk) return ColituWatchAction.spareCarries;
    return ColituWatchAction.reconnect;
  }

  /// True when the device has a usable non-tunnel interface (Wi-Fi `en*` or
  /// cellular `pdp_ip*`) with a routable address. Unknown counts as no
  /// network, so an unreadable state never triggers a switch.
  static Future<bool> deviceHasNetwork() async {
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: false);
      return hasPhysicalNetwork(interfaces);
    } catch (_) {
      return false;
    }
  }

  static bool hasPhysicalNetwork(Iterable<NetworkInterface> interfaces) =>
      physicalNetworkIn(_plain(interfaces));

  /// The device's link kind (wifi, cellular, ethernet, other), the first
  /// half of the Adaptive Connect network key.
  static Future<String> linkKind() async {
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: false);
      return colituLinkKind(_plain(interfaces));
    } catch (_) {
      return 'other';
    }
  }

  static List<(String, List<bool>)> _plain(
    Iterable<NetworkInterface> interfaces,
  ) => [
    for (final interface in interfaces)
      (
        interface.name,
        [
          for (final address in interface.addresses)
            address.isLoopback || address.isLinkLocal,
        ],
      ),
  ];

  /// [hasPhysicalNetwork] on plain data: each interface's name and, per
  /// address, whether it is loopback or link-local. Separate because the
  /// element type of `NetworkInterface.addresses` differs between Dart SDKs.
  static bool physicalNetworkIn(Iterable<(String, List<bool>)> interfaces) {
    for (final (name, local) in interfaces) {
      if (!name.startsWith('en') && !name.startsWith('pdp_ip')) continue;
      if (local.any((isLocal) => !isLocal)) return true;
    }
    return false;
  }
}

enum ColituWatchAction { none, spareCarries, reconnect }

/// Health of the warm spare while the primary is healthy: probed alone
/// through its own check inbound every 60 s (UDP/QUIC spare) or 180 s (TCP
/// spare; each probe opens a connection). [missesToDead] misses in a row
/// while the device is online make it dead; a replacement is swapped in only
/// while the tunnel is quiet ([swapAllowed]).
class ColituSpareWatch {
  ColituSpareWatch({this.missesToDead = 2});

  static const udpInterval = Duration(seconds: 60);
  static const tcpInterval = Duration(seconds: 180);

  /// A reload drops the tunnel's connections: only below this many bytes in
  /// the last [quietWindow].
  static const quietBytes = 10 * 1024;
  static const quietWindow = Duration(seconds: 10);

  final int missesToDead;
  DateTime? _last;
  var _misses = 0;
  var _probing = false;

  int get misses => _misses;

  static Duration intervalFor(String protocol) =>
      protocol == 'hysteria2' ? udpInterval : tcpInterval;

  /// A new spare (or session): the clock starts now.
  void reset(DateTime now) {
    _last = now;
    _misses = 0;
    _probing = false;
  }

  bool due(DateTime now, String protocol) {
    if (_probing) return false;
    final last = _last;
    return last == null || now.difference(last) >= intervalFor(protocol);
  }

  void begin(DateTime now) {
    _probing = true;
    _last = now;
  }

  /// Records a probe. True when the spare is now dead. A miss while the
  /// device is offline does not count.
  bool finish({required bool ok, required bool online}) {
    _probing = false;
    if (ok) {
      _misses = 0;
      return false;
    }
    if (!online) return false;
    _misses++;
    return _misses >= missesToDead;
  }

  static bool swapAllowed(int bytesInQuietWindow) =>
      bytesInQuietWindow < quietBytes;
}
