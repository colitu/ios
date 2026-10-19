import 'package:colitu_vpn/colitu/services/colitu_growth.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';
import 'package:colitu_vpn/colitu/services/colitu_referral.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryKv implements ColituKv {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }
}

const _tpl = 'I use Colitu VPN & friends. Sign up and get {days} of Premium: {link}';
const _link = 'https://colitu.com/r/AB12CD34';

void main() {
  group('share builder', () {
    test('message puts days and link in', () {
      expect(
        ColituShare.message(_tpl, '7 days', _link),
        'I use Colitu VPN & friends. Sign up and get 7 days of Premium: $_link',
      );
    });

    test('telegram url carries the link and the text without the link', () {
      final uri = ColituShare.telegramUri(_tpl, '7 days', _link);
      expect(uri.scheme, 'https');
      expect(uri.host, 't.me');
      expect(uri.path, '/share/url');
      expect(uri.queryParameters['url'], _link);
      final text = uri.queryParameters['text']!;
      expect(text, 'I use Colitu VPN & friends. Sign up and get 7 days of Premium:');
      expect(text.contains('colitu.com/r/'), isFalse);
      expect(uri.toString(), contains('url=https%3A%2F%2Fcolitu.com%2Fr%2FAB12CD34'));
    });

    test('whatsapp url carries the full text incl. link, encoded', () {
      final uri = ColituShare.whatsappUri(_tpl, '7 days', _link);
      expect(uri.host, 'wa.me');
      expect(uri.path, '/');
      expect(uri.queryParameters['text'], ColituShare.message(_tpl, '7 days', _link));
      expect(uri.toString().contains(' '), isFalse);
      expect(uri.toString(), contains('%26'));
    });

    test('only https colitu.com links are shareable', () {
      expect(ColituShare.isShareableLink(_link), isTrue);
      expect(ColituShare.isShareableLink('https://www.colitu.com/r/AB12CD34'), isTrue);
      expect(ColituShare.isShareableLink('http://colitu.com/r/AB12CD34'), isFalse);
      expect(ColituShare.isShareableLink('https://evil.example/r/AB12CD34'), isFalse);
      expect(ColituShare.isShareableLink('https://colitu.com.evil.example/r/x'), isFalse);
      expect(ColituShare.isShareableLink(''), isFalse);
      expect(ColituShare.isShareableLink(null), isFalse);
    });
  });

  group('invite card prefs', () {
    ColituReferral referral({bool enabled = true, String link = _link}) =>
        ColituReferral(code: 'AB12CD34', link: link, enabled: enabled);

    test('hidden until a connection was seen, then stays eligible', () async {
      final kv = _MemoryKv();
      final prefs = ColituInviteCardPrefs(store: kv);
      expect(await prefs.shouldShow(referral()), isFalse);
      await prefs.markConnected();
      expect(await prefs.shouldShow(referral()), isTrue);
      // A fresh instance (app restart) reads the stored flag.
      expect(await ColituInviteCardPrefs(store: kv).shouldShow(referral()), isTrue);
    });

    test('hidden for a disabled programme, no link or a foreign link', () async {
      final prefs = ColituInviteCardPrefs(store: _MemoryKv());
      await prefs.markConnected();
      expect(await prefs.shouldShow(null), isFalse);
      expect(await prefs.shouldShow(referral(enabled: false)), isFalse);
      expect(await prefs.shouldShow(referral(link: 'https://example.com/r/X')), isFalse);
    });

    test('dismiss hides it for 14 days', () async {
      var now = DateTime(2026, 10, 19);
      final prefs = ColituInviteCardPrefs(store: _MemoryKv(), clock: () => now);
      await prefs.markConnected();
      await prefs.dismiss();
      expect(await prefs.shouldShow(referral()), isFalse);
      now = now.add(const Duration(days: 13, hours: 23));
      expect(await prefs.shouldShow(referral()), isFalse);
      now = now.add(const Duration(hours: 2));
      expect(await prefs.shouldShow(referral()), isTrue);
    });
  });
}
