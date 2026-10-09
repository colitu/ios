import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/mfa/page.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/pages/main/url.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Response<dynamic> _response(int status, Map<String, dynamic> body) => Response(
  requestOptions: RequestOptions(path: '/x'),
  statusCode: status,
  data: body,
);

MfaChallenge _challenge({Duration ttl = const Duration(minutes: 5)}) =>
    MfaChallenge(token: 'tok', email: 'ayse@example.com', expiresAt: DateTime.now().add(ttl));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ColituLoc.I.setLanguage('en', persist: false);
  });

  tearDown(() => ColituClock.fix(null));

  group('MFA contract', () {
    test('403 MFA_REQUIRED carries the challenge', () {
      final error = APIException.fromResponse(_response(403, {
        'error': {'code': 'MFA_REQUIRED'},
        'mfa_token': 'abc',
        'mfa_expires_in': 120,
      }));
      expect(error.code, APIErrorCode.mfaRequired);
      final challenge = AuthService.mfaChallengeOf(error, ' ayse@example.com ')!;
      expect(challenge.token, 'abc');
      expect(challenge.email, 'ayse@example.com');
      final ttl = challenge.expiresAt.difference(DateTime.now()).inSeconds;
      expect(ttl, inInclusiveRange(118, 120));
    });

    test('mfa_method defaults to totp and reads email', () {
      final plain = APIException.fromResponse(_response(403, {
        'error': {'code': 'MFA_REQUIRED'},
        'mfa_token': 'abc',
      }));
      expect(AuthService.mfaChallengeOf(plain, 'a@b.c')!.method, 'totp');
      final byMail = APIException.fromResponse(_response(403, {
        'error': {'code': 'MFA_REQUIRED'},
        'mfa_token': 'abc',
        'mfa_method': 'email',
        'mfa_expires_in': 600,
      }));
      expect(AuthService.mfaChallengeOf(byMail, 'a@b.c')!.isEmail, isTrue);
    });

    test('a challenge without a token is not a challenge', () {
      final error = APIException.fromResponse(_response(403, {
        'error': {'code': 'MFA_REQUIRED'},
      }));
      expect(AuthService.mfaChallengeOf(error, 'a@b.c'), isNull);
    });

    test('second step errors map to their codes', () {
      APIErrorCode codeOf(int status, String code) =>
          APIException.fromResponse(_response(status, {'error': {'code': code}})).code;
      expect(codeOf(401, 'MFA_INVALID_CODE'), APIErrorCode.mfaInvalidCode);
      expect(codeOf(401, 'MFA_TOKEN_EXPIRED'), APIErrorCode.mfaTokenExpired);
      expect(codeOf(429, 'RATE_LIMITED'), APIErrorCode.rateLimited);
      expect(codeOf(403, 'MFA_REQUIRED_UPDATE_APP'), APIErrorCode.mfaUpdateRequired);
    });

    test('sign-in advertises the feature', () {
      expect(AuthService.featureHeaders, {'X-Colitu-Features': 'mfa'});
    });
  });

  group('MFA page', () {
    Future<List<String>> pump(
      WidgetTester tester,
      MfaSubmit submit, {
      MfaChallenge? challenge,
    }) async {
      final visited = <String>[];
      final router = GoRouter(
        initialLocation: RouterPath.colituMfa,
        routes: [
          GoRoute(
            path: RouterPath.colituMfa,
            builder: (_, _) => ColituMfaPage(challenge: challenge ?? _challenge(), submit: submit),
          ),
          for (final path in [RouterPath.home, RouterPath.colituAuth, RouterPath.colituVerify])
            GoRoute(
              path: path,
              builder: (_, state) {
                visited.add('$path ${state.extra ?? ''}'.trim());
                return const SizedBox();
              },
            ),
        ],
      );
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp.router(theme: ColituTheme.dark, routerConfig: router));
      await tester.pump();
      return visited;
    }

    Future<void> enter(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.byKey(const ValueKey('mfaSubmit')));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a pasted code with spaces is sent as six digits', (tester) async {
      String? sent;
      final visited = await pump(tester, (_, code) async => sent = code);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofillHints, contains(AutofillHints.oneTimeCode));
      await enter(tester, '123 456');
      expect(sent, '123456');
      expect(visited, [RouterPath.home]);
    });

    testWidgets('too short a code is refused locally', (tester) async {
      var calls = 0;
      await pump(tester, (_, _) async => calls++);
      await enter(tester, '123');
      expect(calls, 0);
      expect(find.text(ColituLoc.I['mfa.err.length']), findsOneWidget);
    });

    testWidgets('a wrong code stays on the page', (tester) async {
      final visited = await pump(tester, (_, _) async {
        throw const APIException(APIErrorCode.mfaInvalidCode, 'x', statusCode: 401);
      });
      await enter(tester, '000000');
      expect(find.text(ColituLoc.I['mfa.err.invalid']), findsOneWidget);
      expect(visited, isEmpty);
    });

    testWidgets('a wrong code shows the attempts left', (tester) async {
      await pump(tester, (_, _) async {
        throw APIException.fromResponse(_response(401, {
          'error': {'code': 'MFA_INVALID_CODE'},
          'attempts_left': 2,
        }));
      });
      await enter(tester, '000000');
      expect(find.text('${ColituLoc.I['mfa.err.invalid']} Attempts left: 2.'), findsOneWidget);
    });

    testWidgets('an expired step goes back to sign-in', (tester) async {
      final visited = await pump(tester, (_, _) async {
        throw const APIException(APIErrorCode.mfaTokenExpired, 'x', statusCode: 401);
      });
      await enter(tester, '111111');
      expect(visited, ['${RouterPath.colituAuth} ${ColituLoc.I['mfa.err.expired']}']);
    });

    testWidgets('an expired challenge never reaches the panel', (tester) async {
      var calls = 0;
      final visited = await pump(
        tester,
        (_, _) async => calls++,
        challenge: _challenge(ttl: const Duration(seconds: -1)),
      );
      await enter(tester, '111111');
      expect(calls, 0);
      expect(visited.single, startsWith(RouterPath.colituAuth));
    });

    testWidgets('rate limiting is shown on the page', (tester) async {
      await pump(tester, (_, _) async {
        throw const APIException(APIErrorCode.rateLimited, 'x', statusCode: 429, backendCode: 'RATE_LIMITED');
      });
      await enter(tester, '222222');
      expect(find.text(ColituLoc.I['err.rateLimited']), findsOneWidget);
    });

    testWidgets('a recovery code keeps its letters', (tester) async {
      String? sent;
      await pump(tester, (_, code) async => sent = code);
      await tester.tap(find.byKey(const ValueKey('mfaToggleRecovery')));
      await tester.pump();
      expect(find.text(ColituLoc.I['mfa.recoveryCode']), findsOneWidget);
      await enter(tester, ' abcd-efgh ');
      expect(sent, 'abcd-efgh');
    });
  });

  group('trial end', () {
    final now = DateTime(2026, 10, 6, 12);

    VPNStatus status(Map<String, dynamic> entitlement, {Map<String, dynamic> extra = const {}}) =>
        VPNStatus.fromJson({
          'user': {'id': 'u1'},
          'entitlement': {'status': 'trialing', ...entitlement},
          ...extra,
        });

    test('bootstrap fields are read', () {
      final trial = status({
        'ends_at': '2026-10-08T12:00:00Z',
        'next_plan': 'free',
        'next_device_limit': 1,
        'next_monthly_gb': 10,
        'device_count': 3,
      }).trial!;
      expect(trial.toFree, isTrue);
      expect(trial.nextDeviceLimit, 1);
      expect(trial.nextMonthlyGb, 10);
      expect(trial.pausesDevices, isTrue);
      final bytes = status({
        'ends_at': '2026-10-08T12:00:00Z',
        'next_plan': {'id': 'free', 'device_limit': 1, 'traffic_limit_bytes': 10737418240},
      }, extra: {'devices': [{}]}).trial!;
      expect(bytes.nextMonthlyGb, 10);
      expect(bytes.deviceCount, 1);
      expect(bytes.pausesDevices, isFalse);
      // Final contract: entitlement.devices = {active, suspended, registered, limit}.
      final counted = status({
        'ends_at': '2026-10-08T12:00:00Z',
        'next_plan': 'free',
        'next_device_limit': 1,
        'devices': {'active': 2, 'suspended': 0, 'registered': 3, 'limit': 5},
      }).trial!;
      expect(counted.deviceCount, 3);
      expect(counted.pausesDevices, isTrue);
      expect(status({'ends_at': '2026-10-08T12:00:00Z'}).trial!.toFree, isFalse);
    });

    test('no trial outside a trial or without an end', () {
      expect(VPNStatus.fromJson({'entitlement': {'status': 'active', 'ends_at': '2026-10-08T12:00:00Z'}}).trial, isNull);
      expect(status({}).trial, isNull);
    });

    test('banner text uses only the panel numbers', () {
      ColituClock.fix(() => now);
      final paused = TrialTransition(
        endsAt: now.add(const Duration(days: 2, hours: 3)),
        nextPlan: 'free',
        nextDeviceLimit: 1,
        nextMonthlyGb: 10,
        deviceCount: 2,
      );
      expect(
        trialBannerText(paused),
        "Your trial ends in 3 days, on 8 October 2026. You'll move to the free plan (10 GB a month, 1 device): "
        'the device you used most recently stays active, the others are paused, not signed out.',
      );
      final simple = TrialTransition(
        endsAt: now.add(const Duration(days: 1)),
        nextPlan: 'free',
        nextDeviceLimit: 1,
        nextMonthlyGb: 10,
        deviceCount: 1,
      );
      expect(
        trialBannerText(simple),
        "Your trial ends in 1 day, on 7 October 2026. You'll move to the free plan (10 GB a month, 1 device).",
      );
      final unknown = TrialTransition(endsAt: now.add(const Duration(hours: 5)), nextPlan: 'free');
      expect(trialBannerText(unknown), "Your trial ends in 5 hours, on 6 October 2026. You'll move to the free plan.");
    });
  });

  test('DEVICE_OVER_LIMIT carries the active devices', () {
    final error = APIException.fromResponse(_response(403, {
      'error': {'code': 'DEVICE_OVER_LIMIT'},
      'device_limit': 1,
      'active_devices': [
        {'id': 'd2', 'name': 'iPad', 'last_seen_at': '2026-10-05T10:00:00Z'},
      ],
    }));
    expect(error.code, APIErrorCode.deviceOverLimit);
    final pause = DevicePause.fromDetails(error.details);
    expect(pause.deviceLimit, 1);
    expect(pause.activeDevices.single.name, 'iPad');
    expect(pause.activeDevices.single.lastSeenAt, DateTime.utc(2026, 10, 5, 10));
  });
}
