import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';

/// Starred servers and the last servers connected to, kept on this device
/// only (never sent to the panel). Entries are server selection keys; a key
/// whose server is no longer in the list is simply not shown.
class ColituServerShortcuts extends ChangeNotifier {
  ColituServerShortcuts({ColituKv? store}) : _store = store ?? PrefsColituKv();

  /// The app-wide store; tests swap in one with an in-memory [ColituKv].
  static ColituServerShortcuts instance = ColituServerShortcuts();

  /// Most recent servers kept (and shown).
  static const maxRecents = 3;

  /// Quick buttons on the home screen.
  static const maxHomeButtons = 3;

  static const _kFavorites = 'colituFavoriteServers';
  static const _kRecents = 'colituRecentServers';

  final ColituKv _store;
  final List<String> _favorites = [];
  final List<String> _recents = [];
  Future<void>? _loading;

  List<String> get favoriteKeys => List.unmodifiable(_favorites);
  List<String> get recentKeys => List.unmodifiable(_recents);

  /// Reads the stored lists once; later calls return the same future.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    _favorites
      ..clear()
      ..addAll(await _read(_kFavorites));
    final recents = await _read(_kRecents);
    _recents
      ..clear()
      ..addAll(recents.take(maxRecents));
    notifyListeners();
  }

  Future<List<String>> _read(String key) async {
    try {
      final raw = await _store.read(key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <String>[];
      for (final item in decoded) {
        if (item is String && item.isNotEmpty && !out.contains(item)) {
          out.add(item);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(String key, List<String> value) async {
    try {
      await _store.write(key, jsonEncode(value));
    } catch (e) {
      debugPrint('Server shortcuts not saved: $e');
    }
  }

  bool isFavorite(VPNServer server) => _favorites.contains(server.selectionKey);

  /// Stars or unstars [server]; new favourites go first.
  Future<void> toggleFavorite(VPNServer server) async {
    await load();
    final key = server.selectionKey;
    if (!_favorites.remove(key)) _favorites.insert(0, key);
    notifyListeners();
    await _write(_kFavorites, _favorites);
  }

  /// Puts [server] at the top of the recent list (at most [maxRecents]).
  Future<void> recordConnected(VPNServer server) async {
    await load();
    final key = server.selectionKey;
    if (_recents.isNotEmpty && _recents.first == key) return;
    _recents
      ..remove(key)
      ..insert(0, key);
    if (_recents.length > maxRecents) {
      _recents.removeRange(maxRecents, _recents.length);
    }
    notifyListeners();
    await _write(_kRecents, _recents);
  }

  /// Favourite servers still in [servers], in starred order.
  List<VPNServer> favorites(Iterable<VPNServer> servers) =>
      _resolve(_favorites, servers);

  /// Recent servers still in [servers], newest first.
  List<VPNServer> recents(Iterable<VPNServer> servers) =>
      _resolve(_recents, servers).take(maxRecents).toList();

  /// The home screen buttons: favourites, then recents, without duplicates
  /// and without [except] (the server already chosen); at most
  /// [maxHomeButtons]. Servers that cannot be picked are left out.
  List<VPNServer> homeButtons(Iterable<VPNServer> servers, {String? except}) {
    final out = <VPNServer>[];
    for (final server in [...favorites(servers), ...recents(servers)]) {
      if (!server.isSelectable) continue;
      if (server.selectionKey == except) continue;
      if (out.any((s) => s.selectionKey == server.selectionKey)) continue;
      out.add(server);
      if (out.length == maxHomeButtons) break;
    }
    return out;
  }

  static List<VPNServer> _resolve(
    List<String> keys,
    Iterable<VPNServer> servers,
  ) {
    final byKey = <String, VPNServer>{
      for (final server in servers) server.selectionKey: server,
    };
    return [
      for (final key in keys)
        if (byKey[key] != null) byKey[key]!,
    ];
  }
}
