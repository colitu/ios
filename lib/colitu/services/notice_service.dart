import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';

/// Colour class of a notice, as the panel names it.
enum NoticeLevel { info, promo, warning, critical }

/// One in-app notice from `GET /client/notices`.
class ClientNotice {
  const ClientNotice({
    required this.id,
    required this.kind,
    required this.level,
    required this.title,
    required this.body,
    this.button,
    this.url,
    this.expiresAt,
  });

  final String id;
  final String kind;
  final NoticeLevel level;
  final String title;
  final String body;
  final String? button;
  final String? url;
  final DateTime? expiresAt;

  /// Null when the entry has no id or nothing to show.
  static ClientNotice? fromJson(Object? json) {
    if (json is! Map) return null;
    String text(String key) {
      final value = json[key];
      return value is String ? value.trim() : '';
    }

    final id = text('id');
    final title = text('title');
    final body = text('body');
    if (id.isEmpty || (title.isEmpty && body.isEmpty)) return null;
    final button = text('button');
    final url = text('url');
    final expires = text('expires_at');
    return ClientNotice(
      id: id,
      kind: text('kind'),
      level: switch (text('level').toLowerCase()) {
        'critical' => NoticeLevel.critical,
        'warning' => NoticeLevel.warning,
        'promo' => NoticeLevel.promo,
        _ => NoticeLevel.info,
      },
      title: title,
      body: body,
      button: button.isEmpty ? null : button,
      url: url.isEmpty ? null : url,
      expiresAt: expires.isEmpty ? null : DateTime.tryParse(expires),
    );
  }

  /// The button is shown only for a web link.
  Uri? get link {
    final raw = url;
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }
}

/// `{"notices":[…]}` → notices; anything else is "none".
List<ClientNotice> parseNotices(Object? json) {
  final list = json is Map ? json['notices'] : null;
  if (list is! List) return const [];
  return [
    for (final item in list)
      ?ClientNotice.fromJson(item),
  ];
}

/// The first notice that is neither dismissed nor expired.
ClientNotice? pickNextNotice(
  List<ClientNotice> notices,
  Set<String> dismissed, {
  DateTime? now,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  for (final notice in notices) {
    if (dismissed.contains(notice.id)) continue;
    final expires = notice.expiresAt;
    if (expires != null && !expires.toUtc().isAfter(at)) continue;
    return notice;
  }
  return null;
}

/// Appends [id] (newest last) and keeps the newest [max] entries.
List<String> addCappedId(List<String> ids, String id, {int max = 200}) {
  final next = [...ids.where((e) => e != id), id];
  return next.length > max ? next.sublist(next.length - max) : next;
}

/// Persistence of the dismissed and already-reported ids.
abstract class NoticeStore {
  Future<List<String>> readDismissed();
  Future<void> saveDismissed(List<String> ids);
  Future<List<String>> readSeen();
  Future<void> saveSeen(List<String> ids);
}

class PrefsNoticeStore implements NoticeStore {
  late final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  static const _dismissedKey = 'colituNoticeDismissed01';
  static const _seenKey = 'colituNoticeSeen01';

  @override
  Future<List<String>> readDismissed() async =>
      await _prefs.getStringList(_dismissedKey) ?? const [];

  @override
  Future<void> saveDismissed(List<String> ids) =>
      _prefs.setStringList(_dismissedKey, ids);

  @override
  Future<List<String>> readSeen() async =>
      await _prefs.getStringList(_seenKey) ?? const [];

  @override
  Future<void> saveSeen(List<String> ids) =>
      _prefs.setStringList(_seenKey, ids);
}

/// Fetches the panel notices at most every [minInterval] and keeps the one
/// banner to show. Every failure (older panel, offline) means "no notice".
class NoticeService extends ChangeNotifier {
  NoticeService({
    ColituVPNService? api,
    NoticeStore? store,
    String Function()? language,
    DateTime Function()? clock,
    this.minInterval = const Duration(minutes: 15),
  }) : _api = api,
       _store = store ?? PrefsNoticeStore(),
       _language = language ?? (() => ColituLoc.I.language),
       _clock = clock ?? DateTime.now;

  static final NoticeService instance = NoticeService();

  final Duration minInterval;
  final NoticeStore _store;
  final String Function() _language;
  final DateTime Function() _clock;
  ColituVPNService? _api;

  ColituVPNService get _service => _api ??= ColituVPNService();

  List<ClientNotice> _notices = const [];
  List<String>? _dismissed;
  List<String>? _seen;
  DateTime? _lastFetch;
  bool _fetching = false;
  ClientNotice? _current;

  ClientNotice? get current => _current;

  Future<void> refresh({bool force = false}) async {
    if (_fetching) return;
    final last = _lastFetch;
    if (!force && last != null && _clock().difference(last) < minInterval) {
      return;
    }
    _fetching = true;
    _lastFetch = _clock();
    try {
      _dismissed ??= await _store.readDismissed();
      _seen ??= await _store.readSeen();
      _notices = await _service.notices(_language());
    } catch (_) {
      _notices = const [];
    } finally {
      _fetching = false;
    }
    _update();
  }

  void _update() {
    final next = pickNextNotice(
      _notices,
      (_dismissed ?? const []).toSet(),
      now: _clock(),
    );
    final changed = next?.id != _current?.id;
    _current = next;
    if (changed) {
      notifyListeners();
      if (next != null) _markSeen(next);
    }
  }

  void _markSeen(ClientNotice notice) {
    final seen = _seen ?? const [];
    if (seen.contains(notice.id)) return;
    _seen = addCappedId(seen, notice.id);
    // Persisted only once the panel has the event; a failed report is tried
    // again on the next launch.
    _guard(() async {
      await _service.noticeEvent(notice.id, 'seen');
      await _store.saveSeen(_seen!);
    });
  }

  /// The button was pressed: reports it; the caller opens the link.
  void clicked(ClientNotice notice) {
    _guard(() => _service.noticeEvent(notice.id, 'clicked'));
  }

  /// The × was pressed: remembers the id and shows the next notice.
  void dismiss(ClientNotice notice) {
    _dismissed = addCappedId(_dismissed ?? const [], notice.id);
    _update();
    _guard(() async {
      await _store.saveDismissed(_dismissed!);
      await _service.noticeEvent(notice.id, 'dismissed');
    });
  }

  void _guard(Future<void> Function() action) {
    action().catchError((Object _) {});
  }
}
