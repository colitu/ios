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

void main() {
  group('invite code', () {
    test('sanitize keeps A-Z0-9, upper-cased, at most 12', () {
      expect(ColituInvite.sanitize(' ab-c 123 '), 'ABC123');
      expect(ColituInvite.sanitize('abcdefghijklmnop'), 'ABCDEFGHIJKL');
      expect(ColituInvite.sanitize(null), '');
    });

    test('normalize accepts 6 to 12 characters only', () {
      expect(ColituInvite.normalize('abc12'), isNull);
      expect(ColituInvite.normalize('abc123'), 'ABC123');
      expect(ColituInvite.normalize('ab c1 23'), 'ABC123');
      expect(ColituInvite.normalize(''), isNull);
      expect(ColituInvite.normalize(null), isNull);
    });

    test('extracts the code from https://colitu.com/r/CODE', () {
      expect(ColituInvite.fromLink('https://colitu.com/r/ab12cd34'), 'AB12CD34');
      expect(ColituInvite.fromLink('https://www.colitu.com/r/AB12CD34/'), 'AB12CD34');
      expect(ColituInvite.fromLink('https://colitu.com/r/AB12CD34?x=1#y'), 'AB12CD34');
      expect(ColituInvite.fromLink('  https://colitu.com/r/AB12CD34  '), 'AB12CD34');
    });

    test('any other URL is not an invite link', () {
      expect(ColituInvite.fromLink('http://colitu.com/r/AB12CD34'), isNull);
      expect(ColituInvite.fromLink('https://evil.example/r/AB12CD34'), isNull);
      expect(ColituInvite.fromLink('https://colitu.com.evil.example/r/AB12CD34'), isNull);
      expect(ColituInvite.fromLink('https://colitu.com/x/AB12CD34'), isNull);
      expect(ColituInvite.fromLink('https://colitu.com/r'), isNull);
      expect(ColituInvite.fromLink('https://colitu.com/r/AB1'), isNull);
      expect(ColituInvite.fromLink(''), isNull);
      expect(ColituInvite.fromLink(null), isNull);
    });

    test('a pasted link or a typed code both end up as the code', () {
      expect(ColituInvite.fromInput('https://colitu.com/r/ab12cd34'), 'AB12CD34');
      expect(ColituInvite.fromInput('ab12-cd34'), 'AB12CD34');
      expect(ColituInvite.fromInput(''), '');
    });

    test('the code of an opened link is kept until sign-up', () async {
      final kv = _MemoryKv();
      expect(await ColituInvite.pending(store: kv), isNull);
      expect(
        await ColituInvite.handleLink('https://colitu.com/r/zz99yy88', store: kv),
        isTrue,
      );
      expect(await ColituInvite.pending(store: kv), 'ZZ99YY88');
      expect(await ColituInvite.handleLink('https://colitu.com/pricing', store: kv), isFalse);
      expect(await ColituInvite.pending(store: kv), 'ZZ99YY88');
      await ColituInvite.keepPending(null, store: kv);
      expect(await ColituInvite.pending(store: kv), isNull);
      expect(kv.map, isEmpty);
    });
  });

  group('referral answer', () {
    test('parses the data object with every counter', () {
      final r = ColituReferral.parse({
        'data': {
          'code': 'AB12CD34',
          'link': 'https://colitu.com/r/AB12CD34',
          'enabled': true,
          'invitee_days': 7,
          'reward_days': 5,
          'monthly_cap': 6,
          'invited': 9,
          'pending': 2,
          'rewarded': 4,
          'rejected': 3,
          'days_earned': 20,
          'rewarded_this_month': 4,
          'recent': [
            {'status': 'rewarded', 'days': 5, 'created_at': '2026-10-01T10:00:00Z'},
            {'status': 'rejected', 'reason': 'same_device', 'days': 0},
          ],
        },
      })!;
      expect(r.link, 'https://colitu.com/r/AB12CD34');
      expect(r.inviteeDays, 7);
      expect(r.rewardDays, 5);
      expect(r.monthlyCap, 6);
      expect([r.invited, r.pending, r.rewarded, r.rejected], [9, 2, 4, 3]);
      expect(r.daysEarned, 20);
      expect(r.left, 2);
      expect(r.recent.map((e) => e.status), ['rewarded', 'rejected']);
      expect(r.recent.last.reason, 'same_device');
    });

    test('defaults, the unwrapped object and a missing link', () {
      final r = ColituReferral.parse({'link': 'https://colitu.com/r/AB12CD34'})!;
      expect([r.inviteeDays, r.rewardDays, r.monthlyCap], [7, 7, 6]);
      expect(r.enabled, isTrue);
      expect(r.left, 6);
      expect(ColituReferral.parse({'data': {'code': 'X'}}), isNull);
      expect(ColituReferral.parse('nope'), isNull);
      expect(ColituReferral.parse(null), isNull);
    });

    test('rewards left never go below zero', () {
      final r = ColituReferral.parse({
        'link': 'https://colitu.com/r/AB12CD34',
        'monthly_cap': 3,
        'rewarded_this_month': 5,
      })!;
      expect(r.left, 0);
    });
  });
}
