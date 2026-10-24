import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:flutter/services.dart';

/// Ping of a location: the TCP connect time to the node's latency probe
/// address (the panel's latency_host / latency_port), best of two tries, like
/// the Windows and Android apps. Only measured while the VPN is off: on iOS
/// the app's own sockets go through the tunnel while it is up, so the number
/// would describe the tunnel plus the path between two nodes. While the VPN
/// is connected the tunnel extension times the connects instead (its own
/// sockets stay outside the tunnel, see [measureAllOutside]); while it is
/// starting or stopping, or the extension does not answer, the list shows
/// the last direct reading.
class ServerLatency {
  static const _timeout = Duration(milliseconds: 2500);

  /// A direct reading is shown this long, on the network it was taken on.
  static const shownFor = Duration(minutes: 30);

  /// The ping shown (and sorted by) for one stored reading: its value when
  /// it was taken on [network] within [shownFor], else null. A failed
  /// reading is null as well.
  static int? shownPing(
    ColituPing? ping, {
    required String network,
    required DateTime now,
  }) {
    if (ping == null || ping.network != network) return null;
    final age = now.difference(ping.at);
    // A clock that went backwards makes the age negative: not shown.
    if (age.isNegative || age >= shownFor) return null;
    return ping.ms;
  }

  /// At most this many probes per run, whatever the server list holds.
  static const maxProbes = 200;

  /// Probes in flight at once.
  static const concurrency = 8;

  /// Ports a latency probe may dial: the nodes' TLS/proxy ports. Anything
  /// else in a server list is not measured, so a bad list cannot turn the app
  /// into a port scanner from the user's own address.
  static const allowedPorts = {
    443, 2053, 2083, 2087, 2096, 3443, 4433, 7443, 8388, 8443, 9443,
  };

  static bool isAllowedPort(int? port) =>
      port != null && allowedPorts.contains(port);

  /// Resolves [host]; null unless every address it resolves to is public
  /// (a literal IP is checked the same way).
  static Future<InternetAddress?> resolvePublic(
    String host, {
    Future<List<InternetAddress>> Function(String host)? lookup,
    bool preferIPv4 = false,
  }) async {
    List<InternetAddress> found;
    try {
      // Resolve first so the DNS lookup is not counted as ping.
      found = await (lookup ?? InternetAddress.lookup)(host).timeout(_timeout);
    } catch (_) {
      return null;
    }
    if (found.isEmpty) return null;
    // VPN nodes are on the internet: a probe name that resolves (even
    // partly) into loopback, private, CGNAT or link-local space is never
    // dialled.
    if (!found.every(isPublic)) return null;
    if (preferIPv4) {
      return found.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => found.first,
      );
    }
    return found.first;
  }

  static Future<int?> measure(String host, int port) async {
    if (!isAllowedPort(port)) return null;
    final address = await resolvePublic(host);
    if (address == null) return null;
    int? best;
    for (var i = 0; i < 2; i++) {
      final watch = Stopwatch()..start();
      try {
        final socket = await Socket.connect(address, port, timeout: _timeout);
        watch.stop();
        socket.destroy();
        final ms = watch.elapsedMilliseconds.clamp(1, 1 << 20);
        if (best == null || ms < best) best = ms;
      } catch (_) {
        // No answer this time.
      }
    }
    return best;
  }

  static bool isPublic(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) return _isPublicV4(b);
    if (b.length != 16) return false;
    bool zeros(int from, int to) =>
        b.sublist(from, to).every((byte) => byte == 0);
    // IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d, used by
    // IPv6-only mobile networks): judge the embedded IPv4 address.
    final mapped = zeros(0, 10) && b[10] == 0xff && b[11] == 0xff;
    final nat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff &&
        b[3] == 0x9b && zeros(4, 12);
    if (mapped || nat64) return _isPublicV4(b.sublist(12));
    final unspecifiedOrLoopback = zeros(0, 15) && b[15] <= 1;
    final uniqueLocal = (b[0] & 0xfe) == 0xfc; // fc00::/7
    final linkOrSiteLocal = b[0] == 0xfe && (b[1] & 0x80) == 0x80; // fe80::/9
    final multicast = b[0] == 0xff;
    final documentation =
        b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8;
    return !(unspecifiedOrLoopback ||
        uniqueLocal ||
        linkOrSiteLocal ||
        multicast ||
        documentation);
  }

  static bool _isPublicV4(List<int> b) {
    if (b.length != 4) return false;
    return !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        b[0] >= 224 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) || // CGNAT
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 198 && (b[1] == 18 || b[1] == 19)) || // benchmarking
        (b[0] == 198 && b[1] == 51 && b[2] == 100) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }

  /// The servers a run probes: a probe address with an allowed port, first
  /// [maxProbes] only.
  static List<VPNServer> probeTargets(List<VPNServer> servers) => [
    for (final server in servers)
      if ((server.host ?? '').isNotEmpty && isAllowedPort(server.port)) server,
  ].take(maxProbes).toList();

  /// Pings of every server with a probe address, by selection key; null for
  /// a probe that timed out or could not be reached (the ranking puts a
  /// server whose fresh ping failed last). At most [concurrency] probes run
  /// at once.
  static Future<Map<String, int?>> measureAll(
    List<VPNServer> servers, {
    Future<int?> Function(String host, int port)? probe,
  }) async {
    final targets = probeTargets(servers);
    final run = probe ?? measure;
    final results = <String, int?>{};
    var next = 0;
    Future<void> worker() async {
      while (next < targets.length) {
        final server = targets[next++];
        int? ms;
        try {
          ms = await run(server.host!, server.port!);
        } catch (_) {
          ms = null;
        }
        results[server.selectionKey] = ms;
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < targets.length; i++) worker(),
    ]);
    return results;
  }

  /// Addresses per request to the tunnel extension (it measures at most
  /// this many at a time).
  static const tunnelBatch = 40;

  /// Pings while the VPN is connected, timed by the tunnel extension: its
  /// own sockets never enter the tunnel (with the strict kill switch too),
  /// so the number is this device's direct path to the node, as with the
  /// VPN off. The app resolves the probe names (while the tunnel is up its
  /// DNS answers, so no poisoned addresses; the lookup is not timed) and
  /// sends literal addresses, [tunnelBatch] at a time; [send] returns the
  /// milliseconds in order (null = no answer), or null when the extension
  /// did not answer at all. Empty when nothing was measured: the caller
  /// keeps the last readings.
  static Future<Map<String, int?>> measureAllOutside(
    List<VPNServer> servers, {
    required Future<List<int?>?> Function(List<TunnelLatencyTarget> targets)
    send,
    Future<InternetAddress?> Function(String host)? resolve,
  }) async {
    final targets = probeTargets(servers);
    final hosts = {for (final server in targets) server.host!}.toList();
    final resolver = resolve ?? (host) => resolvePublic(host, preferIPv4: true);
    final resolved = <String, InternetAddress?>{};
    var next = 0;
    Future<void> worker() async {
      while (next < hosts.length) {
        final host = hosts[next++];
        try {
          resolved[host] = await resolver(host);
        } catch (_) {
          resolved[host] = null;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < hosts.length; i++) worker(),
    ]);
    // One connect per address and port, however many servers share it.
    final unique = <String, TunnelLatencyTarget>{};
    for (final server in targets) {
      final address = resolved[server.host!];
      if (address == null) continue;
      final target = TunnelLatencyTarget(address.address, server.port!);
      unique[target.key] = target;
    }
    if (unique.isEmpty) return const {};
    final list = unique.values.toList();
    final ms = <String, int?>{};
    for (var i = 0; i < list.length; i += tunnelBatch) {
      final batch = list.sublist(i, math.min(i + tunnelBatch, list.length));
      List<int?>? answer;
      try {
        answer = await send(batch);
      } catch (_) {
        answer = null;
      }
      // No answer: what was measured so far stands, the rest is not judged.
      if (answer == null || answer.length != batch.length) break;
      for (var j = 0; j < batch.length; j++) {
        ms[batch[j].key] = answer[j];
      }
    }
    if (ms.isEmpty) return const {};
    return {
      for (final server in targets)
        if (resolved[server.host!] == null)
          server.selectionKey: null
        else if (ms.containsKey(
          TunnelLatencyTarget(
            resolved[server.host!]!.address,
            server.port!,
          ).key,
        ))
          server.selectionKey:
              ms[TunnelLatencyTarget(
                resolved[server.host!]!.address,
                server.port!,
              ).key],
    };
  }
}

/// One address the tunnel extension times a TCP connect to.
class TunnelLatencyTarget {
  const TunnelLatencyTarget(this.address, this.port);

  final String address;
  final int port;

  String get key => '$address|$port';

  Map<String, Object> toJson() => {'address': address, 'port': port};
}

/// The app's line to the tunnel extension for pings while the VPN is up
/// (iOS and the macOS app; the extension answers over its provider message
/// channel).
class TunnelLatency {
  static const _channel = MethodChannel('colitu/tunnel');

  /// Longest wait for one request: 40 addresses, 6 at a time, 2 s each.
  static const _timeout = Duration(seconds: 25);

  /// The probe on this platform; null where no tunnel extension exists.
  static Future<List<int?>?> Function(List<TunnelLatencyTarget> targets)?
  get platformProbe => Platform.isIOS || Platform.isMacOS ? measure : null;

  static Future<List<int?>?> measure(List<TunnelLatencyTarget> targets) async {
    try {
      final raw = await _channel
          .invokeMethod<List<Object?>>('measureLatency', [
            for (final target in targets) target.toJson(),
          ])
          .timeout(_timeout);
      if (raw == null || raw.length != targets.length) return null;
      return [
        for (final value in raw)
          value is int && value >= 0 ? value.clamp(1, 1 << 20) : null,
      ];
    } catch (_) {
      return null;
    }
  }
}
