import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';
import 'package:colitu_vpn/colitu/services/colitu_referral.dart';

/// Pure builders for the one-tap invite shares (Telegram, WhatsApp, system
/// share sheet). The text template comes from the l10n file and holds
/// `{link}`; the days are already formatted by the caller.
abstract final class ColituShare {
  /// True for a link the app is willing to share: https on colitu.com.
  static bool isShareableLink(String? link) {
    if (link == null || link.trim().isEmpty) return false;
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    final host = uri.host.toLowerCase();
    return host == 'colitu.com' || host == 'www.colitu.com';
  }

  /// The full message, with the link at the end.
  static String message(String template, String days, String link) =>
      template.replaceAll('{days}', days).replaceAll('{link}', link.trim()).trim();

  /// The message without the link (Telegram takes the link separately).
  static String messageWithoutLink(String template, String days) =>
      template.replaceAll('{days}', days).replaceAll('{link}', '').trim();

  /// `https://t.me/share/url?url=<link>&text=<text without the link>`.
  static Uri telegramUri(String template, String days, String link) =>
      Uri.parse(
        'https://t.me/share/url?url=${Uri.encodeComponent(link.trim())}'
        '&text=${Uri.encodeComponent(messageWithoutLink(template, days))}',
      );

  /// `https://wa.me/?text=<full text incl. link>`.
  static Uri whatsappUri(String template, String days, String link) => Uri.parse(
    'https://wa.me/?text=${Uri.encodeComponent(message(template, days, link))}',
  );
}

/// Local state of the invite card on the home screen: shown only after the
/// first successful connection on this install (never reset) and hidden for
/// [dismissFor] after the user closes it.
class ColituInviteCardPrefs {
  ColituInviteCardPrefs({ColituKv? store, DateTime Function()? clock})
    : _store = store ?? PrefsColituKv(),
      _clock = clock ?? DateTime.now;

  static final ColituInviteCardPrefs instance = ColituInviteCardPrefs();

  static const dismissFor = Duration(days: 14);
  static const _kEligible = 'colituInviteCardEligible';
  static const _kDismissedAt = 'colituInviteCardDismissedAt';

  final ColituKv _store;
  final DateTime Function() _clock;
  bool? _eligible;

  /// Called whenever the tunnel is connected; stores the flag once.
  Future<void> markConnected() async {
    if (_eligible == true) return;
    _eligible = true;
    try {
      await _store.write(_kEligible, '1');
    } catch (_) {}
  }

  Future<bool> isEligible() async {
    if (_eligible == true) return true;
    try {
      _eligible = await _store.read(_kEligible) == '1';
    } catch (_) {
      _eligible = false;
    }
    return _eligible!;
  }

  Future<void> dismiss() async {
    try {
      await _store.write(_kDismissedAt, '${_clock().millisecondsSinceEpoch}');
    } catch (_) {}
  }

  Future<bool> isDismissed() async {
    try {
      final raw = await _store.read(_kDismissedAt);
      final at = int.tryParse(raw ?? '');
      if (at == null) return false;
      final age = _clock().difference(DateTime.fromMillisecondsSinceEpoch(at));
      // A timestamp in the future (clock set back) is ignored.
      return age < dismissFor && !age.isNegative;
    } catch (_) {
      return false;
    }
  }

  /// Eligible, not dismissed, and the panel gave a usable link.
  Future<bool> shouldShow(ColituReferral? referral) async {
    if (referral == null || !referral.enabled) return false;
    if (!ColituShare.isShareableLink(referral.link)) return false;
    return await isEligible() && !await isDismissed();
  }
}
