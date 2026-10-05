import 'package:colitu_vpn/service/xray/setting/dns_server_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';

/// Optional ad and tracker blocking. When it is on, the tunnel's DNS lookups
/// (already answered by the core, see the DNS rules) go to Colitu's own
/// AdGuard Home servers over DNS-over-HTTPS through the proxy; ad and tracker
/// domains resolve to 0.0.0.0. The servers keep no query log.
class ColituAdBlock {
  ColituAdBlock._();

  /// Tried in order; the next one answers when one is down. The addresses
  /// are not in the source: release builds pass them as a comma-separated
  /// list with `--dart-define=COLITU_ADBLOCK_DOH=https://…/dns-query,…`.
  /// Without it ad blocking is not offered.
  static final dohServers = parse(
    const String.fromEnvironment('COLITU_ADBLOCK_DOH'),
  );

  static bool get available => dohServers.isNotEmpty;

  /// The `https://` URLs of a comma-separated [value], in order.
  static List<String> parse(String value) => List.unmodifiable(
    value
        .split(',')
        .map((url) => url.trim())
        .where((url) => Uri.tryParse(url)?.isScheme('https') ?? false),
  );

  /// Whether a node (by its probe host) runs one of [dohServers]; the server
  /// list tags it.
  static bool hostsDns(String? host, {List<String>? servers}) {
    final value = host?.trim().toLowerCase();
    if (value == null || value.isEmpty) return false;
    return (servers ?? dohServers).any((url) => Uri.parse(url).host == value);
  }

  /// Replaces the general resolvers of [state] with [dohServers]. Resolvers
  /// that only answer for listed domains (local/direct ones) stay as they are.
  static void applyTo(XraySettingState state, {List<String>? servers}) {
    final urls = servers ?? dohServers;
    if (urls.isEmpty) return;
    final general = state.dns.servers.where((s) => s.domains.isEmpty).toList();
    final template = general.isNotEmpty ? general.first : DnsServerState();
    final scoped = state.dns.servers.where((s) => s.domains.isNotEmpty).toList();
    final resolvers = urls.map((url) {
      final server = DnsServerState();
      server.address = url;
      server.tag = template.tag;
      server.queryStrategy = template.queryStrategy;
      return server;
    }).toList();
    state.dns.servers = [...resolvers, ...scoped];
  }
}
