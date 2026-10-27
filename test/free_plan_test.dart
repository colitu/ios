import 'package:flutter_test/flutter_test.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';

ColituUser _free(int usedMb, {String status = 'ACTIVE', DateTime? resetAt}) => ColituUser(
  id: 'u',
  email: 'a@example.com',
  subscriptionStatus: status,
  plan: 'free',
  freeQuota: ColituFreeQuota(
    limitBytes: 1073741824,
    usedBytes: usedMb * 1048576,
    remainingBytes: (1024 - usedMb).clamp(0, 1024) * 1048576,
    resetAt: resetAt,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => ColituLoc.I.setLanguage('en', persist: false));

  test('free plan state: normal below 80 %, near from 80 %, used up at the limit', () {
    expect(freeQuotaStateOf(_free(500)), FreeQuotaState.normal);
    expect(freeQuotaStateOf(_free(820)), FreeQuotaState.near);
    expect(freeQuotaStateOf(_free(1024)), FreeQuotaState.usedUp);
    expect(freeQuotaStateOf(_free(10, status: 'quota_exceeded')), FreeQuotaState.usedUp);
    expect(freeQuotaStateOf(const ColituUser(id: 'u', email: '', plan: 'free')), FreeQuotaState.normal);
  });

  test('free plan line names what is left and the device', () {
    expect(freePlanDetailOf(_free(824)), '200 MB of 1 GB left · 1 device');
    expect(freePlanDetailOf(_free(1024)), '1 GB every month · 1 device');
    expect(
      freePlanDetailOf(const ColituUser(id: 'u', email: '', plan: 'free')),
      '1 GB every month · 1 device',
    );
  });

  test('used up says when the next allowance comes', () {
    final reset = DateTime(2026, 11, 1);
    expect(
      freeQuotaNoticeOf(_free(1024, resetAt: reset)),
      'Your 1 GB for this month is used up. Your next allowance comes on ${ColituLoc.I.date(reset)}.',
    );
    expect(
      freeQuotaNoticeOf(_free(1024)),
      'Your 1 GB for this month is used up. Your next allowance comes next month.',
    );
    expect(freeQuotaNoticeOf(_free(900)), '124 MB left this month.');
  });

  test('every new string has ru, tr and en', () async {
    for (final lang in ['ru', 'tr', 'en']) {
      await ColituLoc.I.setLanguage(lang, persist: false);
      for (final key in [
        'plan.freeLeft',
        'plan.freeNear',
        'plan.freeUsedUp',
        'plan.freeUsedUpLater',
        'plan.premiumPitch',
        'paused.bodyFree',
      ]) {
        expect(ColituLoc.I[key], isNot(key), reason: '$lang $key');
        expect(ColituLoc.I[key], isNotEmpty, reason: '$lang $key');
      }
    }
  });
}
