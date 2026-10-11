import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';

/// Invite (referral) codes. A code is 6-12 characters A-Z0-9; the server
/// ignores unknown ones, so nothing here ever blocks a sign-up.
abstract final class ColituInvite {
  static const minLength = 6;
  static const maxLength = 12;
  static const _kPending = 'colituInvitePending';

  /// Keeps only A-Z0-9, upper-cased and capped; what a text field holds.
  static String sanitize(String? input) {
    final upper = (input ?? '').toUpperCase();
    final kept = upper.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return kept.length > maxLength ? kept.substring(0, maxLength) : kept;
  }

  /// The code to send with the registration, or null when there is none
  /// worth sending (too short or empty).
  static String? normalize(String? input) {
    final code = sanitize(input);
    return code.length >= minLength && code.length <= maxLength ? code : null;
  }

  /// The code in an invite link `https://colitu.com/r/CODE` (a `www.` host,
  /// a trailing slash or a query are fine); null for any other URL.
  static String? fromLink(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    return fromParts(uri.scheme, uri.host, uri.pathSegments);
  }

  static String? fromParts(String? scheme, String? host, List<String> segments) {
    if ((scheme ?? '').toLowerCase() != 'https') return null;
    final h = (host ?? '').toLowerCase();
    if (h != 'colitu.com' && h != 'www.colitu.com') return null;
    if (segments.length < 2 || segments[0] != 'r') return null;
    return normalize(segments[1]);
  }

  /// What a user pasted into the invite field: a link yields its code, plain
  /// text is cleaned up like a typed code. Empty when nothing is left.
  static String fromInput(String? input) => fromLink(input) ?? sanitize(input);

  static final ColituKv _store = PrefsColituKv();
  static String? _pending;
  static var _loaded = false;

  /// The code kept from an opened invite link until the account is created.
  static Future<String?> pending({ColituKv? store}) async {
    if (!_loaded || store != null) {
      try {
        _pending = normalize(await (store ?? _store).read(_kPending));
      } catch (_) {
        _pending = null;
      }
      if (store == null) _loaded = true;
    }
    return _pending;
  }

  static Future<void> keepPending(String? code, {ColituKv? store}) async {
    final value = normalize(code);
    _pending = value;
    if (store == null) _loaded = true;
    try {
      await (store ?? _store).write(_kPending, value);
    } catch (_) {}
  }

  /// Handles an opened link: remembers the code. True when it was an invite.
  static Future<bool> handleLink(String? url, {ColituKv? store}) async {
    final code = fromLink(url);
    if (code == null) return false;
    await keepPending(code, store: store);
    return true;
  }
}

/// `source` of the registration request (where the account was made).
const kColituRegisterSource = 'app:ios';

/// One line of the invite history; never carries a name or an e-mail.
class ColituReferralEvent {
  const ColituReferralEvent({
    required this.status,
    this.reason,
    this.days = 0,
    this.createdAt,
  });

  /// "pending", "rewarded" or "rejected".
  final String status;
  final String? reason;
  final int days;
  final String? createdAt;
}

/// `GET /api/v1/referral`.
class ColituReferral {
  const ColituReferral({
    required this.code,
    required this.link,
    this.enabled = true,
    this.inviteeDays = 7,
    this.rewardDays = 7,
    this.monthlyCap = 6,
    this.invited = 0,
    this.pending = 0,
    this.rewarded = 0,
    this.rejected = 0,
    this.daysEarned = 0,
    this.rewardedThisMonth = 0,
    this.recent = const [],
  });

  final String code;
  final String link;
  final bool enabled;
  final int inviteeDays;
  final int rewardDays;
  final int monthlyCap;
  final int invited;
  final int pending;
  final int rewarded;
  final int rejected;
  final int daysEarned;
  final int rewardedThisMonth;
  final List<ColituReferralEvent> recent;

  /// Rewards still available this month.
  int get left {
    final n = monthlyCap - rewardedThisMonth;
    return n < 0 ? 0 : n;
  }

  /// From the response root (`{"data":{...}}`) or the data object itself;
  /// null without a link.
  static ColituReferral? parse(Object? root) {
    if (root is! Map) return null;
    final data = root['data'] is Map ? root['data'] as Map : root;
    int number(String key, int fallback) {
      final v = data[key];
      return v is num ? v.toInt() : fallback;
    }

    String? text(String key) {
      final v = data[key];
      return v is String ? v : null;
    }

    final link = text('link')?.trim();
    if (link == null || link.isEmpty) return null;
    final recent = <ColituReferralEvent>[];
    final list = data['recent'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        recent.add(
          ColituReferralEvent(
            status: item['status'] is String ? item['status'] as String : '',
            reason: item['reason'] is String ? item['reason'] as String : null,
            days: item['days'] is num ? (item['days'] as num).toInt() : 0,
            createdAt: item['created_at'] is String
                ? item['created_at'] as String
                : null,
          ),
        );
      }
    }
    return ColituReferral(
      code: text('code') ?? '',
      link: link,
      enabled: data['enabled'] is bool ? data['enabled'] as bool : true,
      inviteeDays: number('invitee_days', 7),
      rewardDays: number('reward_days', 7),
      monthlyCap: number('monthly_cap', 6),
      invited: number('invited', 0),
      pending: number('pending', 0),
      rewarded: number('rewarded', 0),
      rejected: number('rejected', 0),
      daysEarned: number('days_earned', 0),
      rewardedThisMonth: number('rewarded_this_month', 0),
      recent: recent,
    );
  }
}

class ColituReferralService {
  ColituReferralService({APIClient? client}) : _injected = client;

  final APIClient? _injected;

  APIClient get _client => _injected ?? APIClient();

  /// The signed-in user's code, link and counters.
  Future<ColituReferral> load() => _client.get(
    APIEndpoint.referral,
    (json) =>
        ColituReferral.parse(json) ??
        (throw const FormatException('Referral answer has no link')),
  );
}
