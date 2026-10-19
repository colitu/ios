import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';

/// The resolvers iOS's own DNS uses while connected (5.9.4): one encrypted
/// DNS-over-HTTPS connection through the tunnel instead of a UDP session per
/// lookup through the core. Each lookup used to cost the tunnel extension
/// several goroutines for up to 30 s, and busy browsing reached the
/// extension's memory cap (an iPhone report of 10-17: 83 lookups open at a
/// memory restart, about 60 % of the core's goroutines).
///
/// Only the panel's list (bootstrap `dns.doh`, ad blocking off) turns it on;
/// the panel sends an empty list since 5.9.7. With ad blocking on the system
/// keeps the classic tunnel DNS and the core filters through the ad-blocking
/// resolvers: on an iPhone of 10-19 (5.9.4-5.9.6) iOS's own DoH client
/// resolved nothing for hours on every transport while the extension's
/// checks of the same resolver through the core passed, so nothing fell
/// back, and no app traffic left the phone. The tunnel
/// extension takes the first one that is not the VPN server itself (that
/// address leaves the tunnel) and falls back to the classic tunnel DNS when
/// none answers. An empty list keeps the classic DNS.
class ColituSystemDoh {
  ColituSystemDoh._();

  static List<String> _panel = const [];

  /// The unfiltered resolvers the panel named last.
  static List<String> get unfiltered => _panel;

  /// The resolver URLs for the tunnel start, in order of preference.
  static List<String> urlsFor({required bool adBlock}) =>
      adBlock ? const [] : _panel;

  /// Reads the list the panel sent earlier (at app start).
  static Future<void> load() async {
    try {
      _panel = ColituAdBlock.parse(
        await PreferencesKey().readColituSystemDoh() ?? '',
      );
    } catch (_) {
      _panel = const [];
    }
  }

  /// Keeps the resolvers of a bootstrap answer. A missing field (an older
  /// panel) keeps the stored list; an explicit empty list clears it, so the
  /// panel can turn the encrypted system DNS off without a release. True
  /// when the list changed.
  static Future<bool> remember(List<String>? servers) async {
    if (servers == null) return false;
    final list = ColituAdBlock.parse(servers.join(','));
    if (_same(list, _panel)) return false;
    _panel = list;
    try {
      await PreferencesKey().saveColituSystemDoh(list.join(','));
    } catch (_) {
      // Kept for this run; the next bootstrap stores it again.
    }
    return true;
  }

  /// Test seam: forgets the panel's list.
  static void resetForTest() => _panel = const [];

  /// `dns.doh` of a bootstrap answer (strings only), null when the answer
  /// has no such field.
  static List<String>? serversOf(Map<String, dynamic> bootstrap) {
    final source = bootstrap['data'] is Map
        ? bootstrap['data'] as Map
        : bootstrap;
    final dns = source['dns'];
    final doh = dns is Map ? dns['doh'] : null;
    if (doh is! List) return null;
    return [
      for (final value in doh)
        if (value is String) value,
    ];
  }

  static bool _same(List<String> a, List<String> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);
}
