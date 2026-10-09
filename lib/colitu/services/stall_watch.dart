import 'dart:io';

/// Decides when a live Hysteria2 tunnel has stalled mid-session.
///
/// Russian mobile networks throttle long-lived UDP flows: the QUIC tunnel
/// stays up but stops carrying traffic, and a call drops. While connected,
/// the controller checks the tunnel every [interval]; after
/// [failuresToSwitch] failed checks in a row (with the device still on a
/// network) it moves to the next transport, at most once per
/// [switchCooldown].
class ColituStallWatch {
  ColituStallWatch({
    this.interval = const Duration(seconds: 5),
    this.failuresToSwitch = 3,
    this.switchCooldown = const Duration(seconds: 60),
    this.flowingBytes = 64 * 1024,
  });

  final Duration interval;
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
    return last == null || now.difference(last) >= interval;
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
  }) {
    _probing = false;
    if (ok || !hasNetwork) {
      _failures = 0;
      return false;
    }
    _failures++;
    if (_failures < failuresToSwitch) return false;
    final last = _lastSwitch;
    if (last != null && now.difference(last) < switchCooldown) return false;
    _failures = 0;
    _lastSwitch = now;
    return true;
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

  static bool hasPhysicalNetwork(Iterable<NetworkInterface> interfaces) {
    for (final interface in interfaces) {
      final name = interface.name;
      if (!name.startsWith('en') && !name.startsWith('pdp_ip')) continue;
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        return true;
      }
    }
    return false;
  }
}
