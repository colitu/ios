import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_referral.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/auth/page.dart';
import 'package:colitu_vpn/pages/colitu/invite/page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeReferral extends ColituReferralService {
  _FakeReferral(this._answers);

  final List<Object> _answers;
  var calls = 0;

  @override
  Future<ColituReferral> load() async {
    final answer = _answers[calls < _answers.length ? calls : _answers.length - 1];
    calls++;
    if (answer is ColituReferral) return answer;
    throw answer;
  }
}

const _referral = ColituReferral(
  code: 'AB12CD34',
  link: 'https://colitu.com/r/AB12CD34',
  inviteeDays: 7,
  rewardDays: 5,
  monthlyCap: 6,
  invited: 9,
  pending: 2,
  rewarded: 4,
  rejected: 3,
  daysEarned: 20,
  rewardedThisMonth: 4,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ColituLoc.I.setLanguage('tr', persist: false);
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: ColituTheme.dark, home: page));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  group('invite screen', () {
    testWidgets('shows the link, four stats and four rules', (tester) async {
      await pump(tester, ColituInvitePage(service: _FakeReferral([_referral])));
      expect(find.text('Arkadaşını davet et'), findsWidgets);
      expect(find.text('https://colitu.com/r/AB12CD34'), findsOneWidget);
      expect(find.text('Davet edilen'), findsOneWidget);
      expect(find.text('Geçerli davet'), findsOneWidget);
      expect(find.text('2 bekliyor'), findsOneWidget);
      expect(find.text('Kazanılan Premium'), findsOneWidget);
      expect(find.text('20 gün'), findsOneWidget);
      expect(find.text('Bu ay kalan ödül'), findsOneWidget);
      expect(find.text('2 / 6'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(ValueKey('inviteRule$i')), findsOneWidget);
      }
      expect(find.text('Arkadaşın e-postasını doğruladığında 7 gün Premium alır.'), findsOneWidget);
      expect(
        find.text('Arkadaşın ilk kez bağlanıp hesabını 24 saat tuttuğunda sen 5 gün Premium kazanırsın.'),
        findsOneWidget,
      );
      expect(
        find.text('Ayda en fazla 6 ödül; günler mevcut Premium süresinin sonuna eklenir.'),
        findsOneWidget,
      );
      expect(find.text('Aynı ağ veya cihaz ve geçici e-postalar sayılmaz.'), findsOneWidget);
      expect(find.byKey(const ValueKey('inviteCopy')), findsOneWidget);
      expect(find.byKey(const ValueKey('inviteShare')), findsOneWidget);
    });

    testWidgets('the share text carries the days and the link', (tester) async {
      expect(
        ColituInvitePage.shareText(_referral),
        'Colitu\'yu deniyorum; bu bağlantıyla hesap açarsan 7 gün Premium hediye. '
        'https://colitu.com/r/AB12CD34',
      );
    });

    testWidgets('Copy puts the link on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester, ColituInvitePage(service: _FakeReferral([_referral])));
      await tester.tap(find.byKey(const ValueKey('inviteCopy')));
      await tester.pump();
      expect(copied, 'https://colitu.com/r/AB12CD34');
      expect(find.text('Bağlantı kopyalandı'), findsOneWidget);
    });

    testWidgets('an error offers a retry that loads again', (tester) async {
      final service = _FakeReferral([
        const APIException(APIErrorCode.networkUnavailable, 'offline'),
        _referral,
      ]);
      await pump(tester, ColituInvitePage(service: service));
      expect(find.byKey(const ValueKey('inviteRetry')), findsOneWidget);
      expect(find.text('https://colitu.com/r/AB12CD34'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('inviteRetry')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(service.calls, 2);
      expect(find.text('https://colitu.com/r/AB12CD34'), findsOneWidget);
    });

    testWidgets('no invitee names or e-mails are shown', (tester) async {
      const withHistory = ColituReferral(
        code: 'AB12CD34',
        link: 'https://colitu.com/r/AB12CD34',
        recent: [
          ColituReferralEvent(status: 'rewarded', days: 5),
          ColituReferralEvent(status: 'rejected', reason: 'same_device'),
        ],
      );
      await pump(tester, ColituInvitePage(service: _FakeReferral([withHistory])));
      expect(find.textContaining('same_device'), findsNothing);
      expect(find.textContaining('@'), findsNothing);
    });
  });

  group('register screen', () {
    testWidgets('the invite code is collapsed until asked for', (tester) async {
      await pump(tester, const ColituAuthPage(register: true));
      expect(find.text('Davet kodum var'), findsOneWidget);
      expect(find.byKey(const ValueKey('inviteField')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('inviteToggle')));
      await tester.tap(find.byKey(const ValueKey('inviteToggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('inviteField')), findsOneWidget);
      expect(find.text('Davet kodum var'), findsNothing);
    });

    testWidgets('a pasted invite link becomes its code', (tester) async {
      await pump(tester, const ColituAuthPage(register: true));
      await tester.ensureVisible(find.byKey(const ValueKey('inviteToggle')));
      await tester.tap(find.byKey(const ValueKey('inviteToggle')));
      await tester.pump();
      final field = find.descendant(
        of: find.byKey(const ValueKey('inviteField')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'https://colitu.com/r/ab12cd34');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'AB12CD34');
      await tester.enterText(field, 'xy-98 zw');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'XY98ZW');
    });
  });
}
