import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_page.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_reveal.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colitu Passport screens at iPhone size with the real font, like
/// colitu_screens_test.dart. Regenerate with
/// `flutter test test/passport_screens_test.dart --update-goldens`.
/// Compared on Windows only (text rasterization differs per OS).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final comparePlatform = Platform.isWindows;
  final now = DateTime(2026, 10, 24, 12);

  setUpAll(() async {
    final loader = FontLoader('Colitu Sans');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final bytes = File('assets/fonts/ColituSans-$weight.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    // The icons, so the review images show them (the font ships in the pub cache).
    final config = File('.dart_tool/package_config.json');
    final match = RegExp(r'"name": "cupertino_icons",\s*"rootUri": "file:///([^"]+)"').firstMatch(config.readAsStringSync());
    final icons = match == null ? null : File('${Uri.decodeFull(match.group(1)!)}/assets/CupertinoIcons.ttf');
    if (icons != null && icons.existsSync()) {
      final iconLoader = FontLoader('packages/cupertino_icons/CupertinoIcons')
        ..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)));
      await iconLoader.load();
    }
  });

  setUp(() async {
    await ColituLoc.I.setLanguage('tr', persist: false);
    // The demo passport of the test build: every level, Nordic set done.
    final p = ColituPassport(store: PassportStore(), clock: () => now)
      ..store.setString('collector_no', '048213')
      ..store.setBool('intro_seen', true)
      ..debugCycle();
    p.goals.updateNickname('Ayşe');
    p.goals.updateTitle('night');
    p.goals.updateFavorite('SE');
    p.rememberCity('SE', 'Stockholm');
    // As the server would report it: the demo's achievements and sets, and
    // today 34 minutes with one piece so far.
    final achievements = [for (final a in PassportAchievement.values) if (p.goals.achieved(a)) a.id];
    final sets = [for (final c in PassportCollection.values) if (p.goals.completed(c)) c.id];
    p.store
      ..setString('srv_ach', achievements.join(','))
      ..setString('srv_col', sets.join(','))
      ..setInt('srv_at', 1)
      ..setString('day', ColituPassport.dayKey(now))
      ..setInt('day_min', 34)
      ..setInt('day_pieces', 1);
    ColituPassport.I = p;
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
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
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 900));
  }

  Future<void> shoot(WidgetTester tester, String name) =>
      expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));

  testWidgets('passport: home', skip: !comparePlatform, (tester) async {
    final c = _controller();
    await pump(tester, PassportPage(controller: c, onConnect: () async {}, showIntro: false, refresh: () async => true));
    await shoot(tester, 'passport_home');
    c.dispose();
  });

  testWidgets('passport: home, stamps further down', skip: !comparePlatform, (tester) async {
    final c = _controller();
    await pump(tester, PassportPage(controller: c, onConnect: () async {}, showIntro: false, refresh: () async => true));
    await tester.drag(find.byType(ListView), const Offset(0, -560));
    await tester.pump(const Duration(milliseconds: 900));
    await shoot(tester, 'passport_home_stamps');
    c.dispose();
  });

  testWidgets('passport: empty passport, first steps', skip: !comparePlatform, (tester) async {
    ColituPassport.I = ColituPassport(store: PassportStore(), clock: () => now)
      ..store.setString('collector_no', '048213');
    final c = _controller();
    await pump(tester, PassportPage(controller: c, onConnect: () async {}, showIntro: false, refresh: () async => true));
    await shoot(tester, 'passport_empty');
    c.dispose();
  });

  testWidgets('passport: stamp sheet', skip: !comparePlatform, (tester) async {
    final c = _controller();
    // Germany: Gold with 4 of 12 pieces (the puzzle and the bar show).
    final stamp = ColituPassport.stampOf('DE')!;
    await pump(
      tester,
      Scaffold(
        backgroundColor: passportInk,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: PassportSheetFrame(
            background: passportSheetBgAsset,
            child: StampSheetBody(controller: c, stamp: stamp, onConnectTo: (_) {}),
          ),
        ),
      ),
    );
    await shoot(tester, 'passport_stamp');
    c.dispose();
  });

  testWidgets('passport: customize', skip: !comparePlatform, (tester) async {
    await pump(tester, const PassportIdentityPage(premium: true));
    await shoot(tester, 'passport_customize');
  });

  testWidgets('customize: the save button hides while the keyboard is up', (tester) async {
    Widget page(double keyboard) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(393, 852), viewInsets: EdgeInsets.only(bottom: keyboard)),
        child: const PassportIdentityPage(premium: false),
      ),
    );
    await tester.pumpWidget(page(0));
    expect(find.byKey(const ValueKey('passportSave')), findsOneWidget);
    await tester.pumpWidget(page(300));
    expect(find.byKey(const ValueKey('passportSave')), findsNothing);
  });

  testWidgets('reveal: Reduce Motion opens in the final state', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    final shown = showPassportReward(ctx, const StampEvent.unlocked('JP'), premium: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Final state at once: the title and the buttons, no 2.4 s timeline.
    expect(find.text(ColituLoc.I['passport.r.add']), findsOneWidget);
    await tester.tap(find.text(ColituLoc.I['passport.r.add']));
    await tester.pumpAndSettle();
    await shown;
  });

  testWidgets('home card', skip: !comparePlatform, (tester) async {
    await pump(
      tester,
      Scaffold(
        backgroundColor: ColituColors.bg,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 120, 20, 0),
          child: Column(children: [PassportCard(premium: true, onOpen: () {})]),
        ),
      ),
    );
    await shoot(tester, 'passport_card');
  });
}

ColituConnectionController _controller() {
  return ColituConnectionController()
    ..loading = false
    ..servers = [
      VPNServer.fromJson({'id': 'se1', 'name': 'Sweden', 'countryCode': 'SE', 'city': 'Stockholm', 'available': true}),
      VPNServer.fromJson({'id': 'us1', 'name': 'USA', 'countryCode': 'US', 'city': 'New York', 'available': true}),
    ]
    ..panelStatus = const VPNStatus(
      authenticated: true,
      subscriptionActive: true,
      tier: 'pro',
      premiumAllowed: true,
      vpnAccountReady: true,
    );
}
