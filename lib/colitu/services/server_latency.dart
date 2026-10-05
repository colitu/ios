import 'dart:async';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';

/// Ping of a location: the TCP connect time to the node's latency probe
/// address (the panel's latency_host / latency_port), best of two tries, like
/// the Windows and Android apps. Only measured while the VPN is off: through
/// the tunnel the number would describe the path between two nodes.
class ServerLatency {
  static const _timeout = Duration(milliseconds: 2500);

  static Future<int?> measure(String host, int port) async {
    InternetAddress address;
    try {
      // Resolve first so the DNS lookup is not counted as ping.
      final found = await InternetAddress.lookup(host).timeout(_timeout);
      if (found.isEmpty) return null;
      address = found.first;
    } catch (_) {
      return null;
    }
    if (!isPublic(address)) {
      // VPN nodes are on the internet: a probe address in loopback, private,
      // CGNAT or link-local space (a bad server list) is never dialled.
      return null;
    }
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
    if (address.type == InternetAddressType.IPv4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168));
    }
    // IPv6: unspecified, unique local (fc00::/7) and IPv4-mapped addresses.
    final unspecified = b.every((byte) => byte == 0);
    final uniqueLocal = (b[0] & 0xfe) == 0xfc;
    final mapped = b.sublist(0, 10).every((byte) => byte == 0) && b[10] == 0xff && b[11] == 0xff;
    return !(unspecified || uniqueLocal || mapped);
  }

  /// Pings of every server with a probe address, by selection key.
  static Future<Map<String, int>> measureAll(List<VPNServer> servers) async {
    final probes = [
      for (final server in servers)
        if ((server.host ?? '').isNotEmpty &&
            (server.port ?? 0) > 0 &&
            (server.port ?? 0) < 65536)
          measure(
            server.host!,
            server.port!,
          ).then((ms) => MapEntry(server.selectionKey, ms)),
    ];
    final results = await Future.wait(probes);
    return {
      for (final entry in results)
        if (entry.value != null) entry.key: entry.value!,
    };
  }
}
