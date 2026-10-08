import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';

/// Servers of one country, in the order the list was sorted. A group with one
/// server is drawn as a plain server row, with two or more as an expandable
/// country header.
class ServerGroup {
  const ServerGroup(this.key, this.servers);

  /// Country code (upper case); unique per server when none is known.
  final String key;
  final List<VPNServer> servers;

  bool get isSingle => servers.length == 1;

  bool contains(String? selectionKey) =>
      selectionKey != null &&
      servers.any((s) => s.selectionKey == selectionKey);

  /// Lowest ping among the servers that can be picked, null when none known.
  int? bestPing(int? Function(VPNServer server) pingOf) =>
      bestPingOf(servers, pingOf);
}

/// Lowest known ping among the selectable [servers].
int? bestPingOf(
  Iterable<VPNServer> servers,
  int? Function(VPNServer server) pingOf,
) {
  int? best;
  for (final server in servers) {
    if (!server.isSelectable) continue;
    final ping = pingOf(server);
    if (ping != null && (best == null || ping < best)) best = ping;
  }
  return best;
}

/// Groups an already filtered and sorted list by country code.
///
/// Groups appear in the order their first server appears and the servers keep
/// their order inside a group, so whatever sort produced [servers] applies to
/// the countries and to the cities alike. With [flat] (a search is active)
/// every server stays its own group, in the original order.
List<ServerGroup> groupServersByCountry(
  List<VPNServer> servers, {
  bool flat = false,
}) {
  if (flat) {
    return [
      for (final s in servers) ServerGroup(_key(s, unique: true), [s]),
    ];
  }
  final order = <String>[];
  final byKey = <String, List<VPNServer>>{};
  for (final server in servers) {
    final key = _key(server);
    final list = byKey[key];
    if (list == null) {
      order.add(key);
      byKey[key] = [server];
    } else {
      list.add(server);
    }
  }
  return [for (final key in order) ServerGroup(key, byKey[key]!)];
}

String _key(VPNServer server, {bool unique = false}) {
  final code = server.countryCode;
  if (!unique && code.isNotEmpty) return code;
  return code.isEmpty
      ? 'id:${server.selectionKey}'
      : '$code:${server.selectionKey}';
}

/// Whether [group] is open: the user's own choice in [overrides] wins,
/// otherwise a group starts open when it holds the selected server.
bool isGroupExpanded(
  ServerGroup group, {
  required String? selectedKey,
  Map<String, bool> overrides = const {},
}) => overrides[group.key] ?? group.contains(selectedKey);

/// City label of a row inside a country group: the server's city, else its
/// usual name.
String serverCityLabel(VPNServer server) {
  final city = server.city?.trim() ?? '';
  return city.isNotEmpty ? city : server.displayTitle;
}
