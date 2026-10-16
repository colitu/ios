import 'dart:io';

import 'package:colitu_vpn/colitu/services/server_latency.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/service/xray/setting/dns_server_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';

/// Optional ad and tracker blocking. When it is on, the tunnel's DNS lookups
/// (already answered by the core, see the DNS rules) go to Colitu's own
/// AdGuard Home servers over DNS-over-HTTPS through the proxy; ad and tracker
/// domains resolve to 0.0.0.0. The servers keep no query log.
class ColituAdBlock {
  ColituAdBlock._();

  /// Tried in order; the next one answers when one is down. They come from
  /// the panel with the signed-in bootstrap (`ad_block.doh`, kept by
  /// [remember]), like on Android, Windows and Linux: Colitu's own nodes,
  /// replaceable without a release. Until the panel has named any, the
  /// build's list is used (`--dart-define=COLITU_ADBLOCK_DOH=https://…,…`,
  /// set on Codemagic). With neither, ad blocking is not offered.
  static List<String> get dohServers => _panel.isNotEmpty ? _panel : _build;

  static final List<String> _build = parse(
    const String.fromEnvironment('COLITU_ADBLOCK_DOH'),
  );
  static List<String> _panel = const [];

  static bool get available => dohServers.isNotEmpty;

  /// Reads the list the panel sent earlier (at app start).
  static Future<void> load() async {
    try {
      _panel = parse(await PreferencesKey().readColituAdBlockDoh() ?? '');
    } catch (_) {
      _panel = const [];
    }
  }

  /// Keeps the resolvers of a bootstrap answer. Only a non-empty list
  /// replaces the stored one: an answer without the field (an older panel)
  /// or with an empty list (a panel whose list is not set) never turns ad
  /// blocking off. True when the list changed.
  static Future<bool> remember(List<String>? servers) async {
    final list = parse((servers ?? const []).join(','));
    if (list.isEmpty || _sameList(list, _panel)) return false;
    _panel = list;
    try {
      await PreferencesKey().saveColituAdBlockDoh(list.join(','));
    } catch (_) {
      // Kept for this run; the next bootstrap stores it again.
    }
    return true;
  }

  /// Test seam: forgets the panel's list.
  static void resetForTest() => _panel = const [];

  /// `ad_block.doh` of a bootstrap answer (strings only), null when the
  /// answer has no such field.
  static List<String>? serversOf(Map<String, dynamic> bootstrap) {
    final source = bootstrap['data'] is Map
        ? bootstrap['data'] as Map
        : bootstrap;
    final adBlock = source['ad_block'];
    final doh = adBlock is Map ? adBlock['doh'] : null;
    if (doh is! List) return null;
    return [
      for (final value in doh)
        if (value is String) value,
    ];
  }

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

  /// The `https://` URLs of a comma-separated [value], in order.
  /// At most this many resolvers are kept (as on Android).
  static const maxServers = 8;

  /// The `https://` URLs of a comma-separated [value], in order, without
  /// repeats and at most [maxServers]. A URL whose host is a local name or
  /// an address outside the open internet (loopback, private, link-local,
  /// documentation ranges; the list of the latency probe) is dropped, like
  /// on Android: a spoofed list must not point the resolver into the local
  /// network.
  static List<String> parse(String value) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in value.split(',')) {
      final url = raw.trim();
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) continue;
      if (!_publicHost(uri.host)) continue;
      if (!seen.add(url)) continue;
      out.add(url);
      if (out.length == maxServers) break;
    }
    return List.unmodifiable(out);
  }

  static bool _publicHost(String host) {
    final h = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (h == 'localhost' || !h.contains('.') && !h.contains(':')) return false;
    if (h.endsWith('.localhost') || h.endsWith('.local')) return false;
    final address = InternetAddress.tryParse(h);
    return address == null || ServerLatency.isPublic(address);
  }

  /// Whether a node (by its probe host) runs one of [dohServers]; the server
  /// list tags it.
  static bool hostsDns(String? host, {List<String>? servers}) {
    final value = host?.trim().toLowerCase();
    if (value == null || value.isEmpty) return false;
    return (servers ?? dohServers).any((url) => Uri.parse(url).host == value);
  }

  /// Per-query timeout of an ad-blocking resolver. Xray waits 4 s by
  /// default; a DoH request stuck on a stale HTTP/2 connection after a wake
  /// held every lookup behind it that long (168 timeouts in 50 minutes in
  /// one diagnostic), before the next server was even asked.
  static const dohTimeoutMs = 3000;

  /// Plain resolver asked when every ad-blocking one failed. It goes through
  /// the tunnel like the others (the DNS query rule sends the core's lookups
  /// to the proxy), as a new TCP connection per query, so it does not share
  /// a stalled DoH connection. Ads are not blocked for such a lookup, but
  /// the page loads.
  static const fallbackResolver = 'tcp://1.1.1.1';

  /// Puts [dohServers] in front of the general resolvers of [state].
  /// Resolvers that only answer for listed domains (local/direct ones) stay
  /// as they are. The app's own plain resolver (or [fallbackResolver] when
  /// it was a DoH one) stays last as a fallback: Xray asks the servers in
  /// order and moves on after an error or a timeout.
  static void applyTo(XraySettingState state, {List<String>? servers}) {
    final urls = servers ?? dohServers;
    if (urls.isEmpty) return;
    final general = state.dns.servers.where((s) => s.domains.isEmpty).toList();
    final template = general.isNotEmpty ? general.first : DnsServerState();
    final scoped = state.dns.servers
        .where((s) => s.domains.isNotEmpty)
        .toList();
    final resolvers = urls.map((url) {
      final server = DnsServerState();
      server.address = url;
      server.tag = template.tag;
      server.queryStrategy = template.queryStrategy;
      server.timeoutMs = dohTimeoutMs;
      return server;
    }).toList();
    final plain = template.address.trim();
    final fallback = DnsServerState()
      ..address = _plainResolver(plain) ? plain : fallbackResolver
      ..tag = template.tag
      ..queryStrategy = template.queryStrategy;
    state.dns.servers = [...resolvers, fallback, ...scoped];
  }

  /// A plain DNS server by address (`1.1.1.1`, `tcp://1.1.1.1`): no DoH
  /// connection to share, and no system resolver (`localhost`) outside the
  /// tunnel.
  static bool _plainResolver(String address) {
    final host = address.startsWith('tcp://')
        ? address.substring('tcp://'.length).split(':').first
        : address;
    return InternetAddress.tryParse(host) != null;
  }
}
