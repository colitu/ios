import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/user_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/auth/page.dart';
import 'package:colitu_vpn/pages/colitu/mfa/page.dart';
import 'package:colitu_vpn/pages/colitu/paused/page.dart';
import 'package:colitu_vpn/pages/colitu/rotation/page.dart';
import 'package:colitu_vpn/pages/colitu/split_tunnel/page.dart';
import 'package:colitu_vpn/pages/colitu/onboarding/page.dart';
import 'package:colitu_vpn/pages/colitu/shell/account_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/locations_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/plan_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/support_tab.dart';
import 'package:colitu_vpn/pages/colitu/verify/page.dart';
import 'package:colitu_vpn/colitu/services/support_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Renders every screen of the signed-in shell, the tour and the auth page at
/// iPhone size with the real Colitu Sans font, so the design can be reviewed
/// on a machine that cannot run the iOS build. Regenerate with
/// `flutter test test/colitu_screens_test.dart --update-goldens`.
///
/// Text rasterization differs per OS, so the goldens are only compared on
/// the platform that generated them (Windows); CI on macOS skips them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final comparePlatform = Platform.isWindows;

  setUpAll(() async {
    final loader = FontLoader('Colitu Sans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final bytes = File(
        'assets/fonts/ColituSans-$weight.ttf',
      ).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    PackageInfo.setMockInitialValues(
      appName: 'Colitu',
      packageName: 'com.colitu.vpn',
      version: '5.2.0',
      buildNumber: '17',
      buildSignature: '',
    );
  });

  setUp(() async {
    await ColituLoc.I.setLanguage('tr', persist: false);
    AppSession.instance.currentUser = _user;
    // Plan dates and day counts would otherwise change every day.
    ColituClock.fix(() => _now);
  });

  tearDown(() => ColituClock.fix(null));

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ColituTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(393, 852),
            devicePixelRatio: 3,
            padding: EdgeInsets.only(top: 59, bottom: 34),
          ),
          child: page,
        ),
      ),
    );
    // Three frames: data loads, reveal timers fire, reveal animations finish.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await precacheImages(tester);
  }

  Future<void> shoot(WidgetTester tester, Widget page, String name) async {
    await pumpPage(tester, page);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('onboarding', skip: !comparePlatform, (tester) async {
    await shoot(tester, const ColituOnboardingPage(), 'onboarding');
  });

  testWidgets('auth: sign in', skip: !comparePlatform, (tester) async {
    await shoot(tester, const ColituAuthPage(), 'auth_login');
  });

  testWidgets('auth: sign up', skip: !comparePlatform, (tester) async {
    await pumpPage(tester, const ColituAuthPage());
    await tester.tap(find.text(ColituLoc.I['auth.register']));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/auth_register.png'),
    );
  });

  testWidgets('home: not connected', skip: !comparePlatform, (tester) async {
    final c = _controller();
    await shoot(
      tester,
      _shell(
        HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () {},
        ),
      ),
      'home_off',
    );
    c.dispose();
  });

  testWidgets('home: connected', skip: !comparePlatform, (tester) async {
    final c = _controller()
      ..status = ColituVpnStatus.connected
      ..connectedServer = _servers.first
      ..verified = true
      ..transport = 'hysteria2'
      ..verifiedPublicIp = '203.0.113.10'
      ..uploadBps = 412000
      ..downloadBps = 8930000
      ..connectedSeconds = 754;
    await shoot(
      tester,
      _shell(
        HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () {},
        ),
      ),
      'home_on',
    );
    c.dispose();
  });

  testWidgets('home: connecting with an error banner', skip: !comparePlatform, (
    tester,
  ) async {
    final c = _controller()
      ..status = ColituVpnStatus.connecting
      ..phase = ColituConnectPhase.probing
      ..error = ColituLoc.I['err.unreachable'];
    await shoot(
      tester,
      _shell(
        HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () {},
        ),
      ),
      'home_connecting',
    );
    c.dispose();
  });

  testWidgets('locations', skip: !comparePlatform, (tester) async {
    final c = _controller()
      ..status = ColituVpnStatus.connected
      ..connectedServer = _servers.first
      ..autoSelection = false
      ..selectedServer = _servers.first;
    await shoot(
      tester,
      _shell(LocationsTab(controller: c, onOpenPlan: () {})),
      'locations',
    );
    c.dispose();
  });

  testWidgets('locations: streaming filter', skip: !comparePlatform, (
    tester,
  ) async {
    final c = _controller();
    await pumpPage(
      tester,
      _shell(LocationsTab(controller: c, onOpenPlan: () {}), index: 1),
    );
    await tester.tap(find.text('Streaming').first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await precacheImages(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/locations_streaming.png'),
    );
    c.dispose();
  });

  testWidgets('support: requests', skip: !comparePlatform, (tester) async {
    final c = _controller()..supportUnread = 1;
    await shoot(
      tester,
      _shell(SupportTab(controller: c, service: _FakeSupport()), index: 3),
      'support',
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('support: chat', skip: !comparePlatform, (tester) async {
    final c = _controller();
    await pumpPage(
      tester,
      _shell(SupportTab(controller: c, service: _FakeSupport()), index: 3),
    );
    await tester.tap(find.text('Estonya sunucusu yavaş'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/support_chat.png'),
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('verify e-mail', skip: !comparePlatform, (tester) async {
    await shoot(tester, const ColituVerifyPage(codeJustSent: true), 'verify');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('plan', skip: !comparePlatform, (tester) async {
    final c = _controller();
    await shoot(tester, _shell(PlanTab(controller: c)), 'plan');
    c.dispose();
  });

  testWidgets('home: trial ends, split tunneling on', skip: !comparePlatform, (
    tester,
  ) async {
    final c = _controller()
      ..status = ColituVpnStatus.connected
      ..connectedServer = _servers.first
      ..verified = true
      ..transport = 'vless-reality'
      ..splitTunnel = const SplitTunnelSettings(
        mode: SplitTunnelMode.bypass,
        domains: ['sberbank.ru', 'gosuslugi.ru'],
        ips: ['203.0.113.0/24'],
      )
      ..panelStatus = VPNStatus(
        authenticated: true,
        subscriptionActive: true,
        tier: 'trial',
        premiumAllowed: true,
        vpnAccountReady: true,
        trial: TrialTransition(
          endsAt: _now.add(const Duration(days: 2, hours: 5)),
          nextPlan: 'free',
          nextDeviceLimit: 1,
          nextMonthlyGb: 10,
          deviceCount: 2,
        ),
      );
    await shoot(
      tester,
      _shell(
        HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () {},
        ),
      ),
      'home_trial',
    );
    c.dispose();
  });

  testWidgets('paused device', skip: !comparePlatform, (tester) async {
    final c = _controller()
      ..paused = DevicePause(
        deviceLimit: 1,
        activeDevices: [
          PausedPeer(
            id: 'd2',
            name: 'DESKTOP-ALICA',
            lastSeenAt: _now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
    await shoot(tester, _shell(ColituPausedView(controller: c)), 'paused');
    c.dispose();
  });

  testWidgets('split tunneling', skip: !comparePlatform, (tester) async {
    final c = _controller()
      ..splitTunnel = const SplitTunnelSettings(
        mode: SplitTunnelMode.bypass,
        domains: ['sberbank.ru', 'gosuslugi.ru'],
        ips: ['203.0.113.0/24'],
      );
    await shoot(tester, ColituSplitTunnelPage(controller: c), 'split_tunnel');
    c.dispose();
  });

  testWidgets('two-step sign-in', skip: !comparePlatform, (tester) async {
    await shoot(
      tester,
      ColituMfaPage(
        challenge: MfaChallenge(
          token: 't',
          email: 'ayse@example.com',
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        ),
      ),
      'mfa',
    );
  });

  testWidgets('rotating IP', skip: !comparePlatform, (tester) async {
    final c = _controller()..rotation = _rotation;
    await shoot(tester, ColituRotationPage(controller: c), 'rotation');
    c.dispose();
  });

  testWidgets('account', skip: !comparePlatform, (tester) async {
    final c = _controller()..rotation = _rotation;
    await shoot(
      tester,
      _shell(
        AccountTab(
          controller: c,
          onOpenPlan: () {},
          onSignOut: () async {},
          users: _FakeUsers(),
        ),
      ),
      'account',
    );
    c.dispose();
  });
}

Widget _shell(Widget tab, {int index = 0}) {
  return ColituScaffold(
    padding: EdgeInsets.zero,
    safeBottom: false,
    bottomNavigationBar: ColituNavBar(
      items: [
        ColituNavItem(icon: Icons.home_rounded, label: ColituLoc.I['nav.home']),
        ColituNavItem(
          icon: Icons.public_rounded,
          label: ColituLoc.I['nav.locations'],
        ),
        ColituNavItem(
          icon: Icons.card_giftcard_rounded,
          label: ColituLoc.I['nav.plan'],
        ),
        ColituNavItem(
          icon: Icons.chat_bubble_rounded,
          label: ColituLoc.I['nav.support'],
          badge: 1,
        ),
        ColituNavItem(
          icon: Icons.person_rounded,
          label: ColituLoc.I['nav.account'],
        ),
      ],
      index: index,
      onChanged: (_) {},
    ),
    child: tab,
  );
}

ColituConnectionController _controller() {
  return ColituConnectionController()
    ..loading = false
    ..servers = _servers
    ..alwaysOn = true
    ..panelStatus = const VPNStatus(
      authenticated: true,
      subscriptionActive: true,
      tier: 'pro',
      premiumAllowed: true,
      vpnAccountReady: true,
    );
}

/// Rotation every 10 minutes over the default set; Russia is listed unchecked.
final _rotation = RotationPreference.fromJson({
  'interval_seconds': 600,
  'countries': <String>[],
  'intervals': [300, 600, 1800],
  'available_countries': [
    {'country': 'DE', 'in_default': true, 'exits': 2},
    {'country': 'NL', 'in_default': true, 'exits': 1},
    {'country': 'FI', 'in_default': true, 'exits': 1},
    {'country': 'SE', 'in_default': true, 'exits': 1},
    {'country': 'RU', 'in_default': false, 'exits': 1},
  ],
  'protocols': ['vless-reality', 'vless-xhttp'],
  'changes_exit_country': true,
});

/// The goldens' "now" (a fixed day, so plan dates never drift).
final _now = DateTime(2026, 10, 6, 12);

final _user = ColituUser(
  id: 'u1',
  email: 'ayse@example.com',
  deviceLimit: 3,
  subscriptionStatus: 'ACTIVE',
  plan: 'Colitu VPN · 12 ay',
  // A minute short of 212 days: "211 days left", as the goldens show.
  expiresAt: _now.add(const Duration(days: 212, minutes: -1)),
  premiumAllowed: true,
);

final _servers = [
  VPNServer.fromJson({
    'id': 'ee1',
    'name': 'Estonya',
    'countryCode': 'EE',
    'city': 'Tallinn',
    'available': true,
    'load': 18,
    'recommended': true,
    'ping': 41,
    'categories': ['streaming', 'privacy', 'ai'],
    'services': ['chatgpt', 'gemini', 'claude', 'netflix', 'youtube_premium'],
  }),
  VPNServer.fromJson({
    'id': 'gb1',
    'name': 'Birleşik Krallık',
    'countryCode': 'GB',
    'city': 'Coventry',
    'available': true,
    'load': 30,
    'recommended': true,
    'ping': 38,
    'services': ['chatgpt', 'gemini', 'claude', 'netflix'],
  }),
  VPNServer.fromJson({
    'id': 'de1',
    'name': 'Almanya',
    'countryCode': 'DE',
    'city': 'Frankfurt',
    'available': true,
    'load': 52,
    'ping': 58,
    'categories': ['gaming', 'speed'],
    'services': ['chatgpt', 'gemini'],
  }),
  VPNServer.fromJson({
    'id': 'nl1',
    'name': 'Hollanda',
    'countryCode': 'NL',
    'city': 'Amsterdam',
    'available': true,
    'load': 81,
    'premium': true,
    'ping': 132,
    'categories': ['streaming', 'torrent'],
  }),
  VPNServer.fromJson({
    'id': 'tr1',
    'name': 'Türkiye',
    'countryCode': 'TR',
    'city': 'İstanbul',
    'available': false,
    'load': 0,
  }),
];

class _FakeUsers extends UserService {
  @override
  Future<List<ColituDevice>> devices() async => [
    ColituDevice(
      id: 'd1',
      name: 'iPhone 15 Pro',
      current: true,
      platform: 'ios',
      lastActiveAt: DateTime.now(),
    ),
    ColituDevice(
      id: 'd2',
      name: 'DESKTOP-ALICA',
      platform: 'windows',
      lastActiveAt: DateTime.now().subtract(const Duration(days: 2)),
    ),
  ];
}

class _FakeSupport extends ColituSupportService {
  // Fixed, so the goldens do not change with the clock.
  static final _now = DateTime(2026, 9, 25, 14, 0);

  @override
  Future<List<SupportConversation>> conversations() async => [
    SupportConversation(
      id: 'c1',
      subject: 'Estonya sunucusu yavaş',
      status: 'open',
      unread: 1,
      lastMessage: 'Harika, sorun çözüldü diye işaretliyorum.',
      lastMessageAt: _now.subtract(const Duration(minutes: 10)),
    ),
    SupportConversation(
      id: 'c2',
      subject: 'Ödeme sonrası paket görünmüyor',
      status: 'resolved',
      unread: 0,
      lastMessage: 'Paketiniz aktif edildi, iyi kullanımlar!',
      lastMessageAt: _now.subtract(const Duration(days: 6)),
    ),
  ];

  @override
  Future<(SupportConversation?, List<SupportMessage>)> thread(String id) async {
    final list = await conversations();
    return (
      list.first,
      [
        SupportMessage(
          id: 'm1',
          sender: 'user',
          body: 'Merhaba, akşamları Estonya sunucusunda hız 5 Mbps’e düşüyor.',
          createdAt: _now.subtract(const Duration(hours: 3)),
          attachments: const [
            SupportAttachment(
              id: 'a1',
              fileName: 'colitu-log.txt',
              contentType: 'text/plain',
              size: 18234,
              isImage: false,
            ),
          ],
        ),
        SupportMessage(
          id: 'm2',
          sender: 'admin',
          adminName: 'Deniz',
          body:
              'Tanılama bilgilerinize baktık; akşam saatlerinde VLESS daha stabil olacaktır. Uygulamayı yeniden başlatıp dener misiniz?',
          createdAt: _now.subtract(const Duration(hours: 2)),
          attachments: const [],
        ),
        SupportMessage(
          id: 'm3',
          sender: 'user',
          body: 'Denedim, şimdi çok daha iyi. Teşekkürler!',
          createdAt: _now.subtract(const Duration(minutes: 20)),
          attachments: const [],
        ),
      ],
    );
  }
}

/// Asset images (the round flags) decode outside the fake clock; load them
/// for real before the screenshot.
Future<void> precacheImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final widget = element.widget as Image;
      await precacheImage(widget.image, element);
    }
  });
  await tester.pump();
}
