import 'dart:convert';

import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/server_shortcuts.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/locations_tab.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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

VPNServer _server(
  String id,
  String country, {
  String? city,
  bool available = true,
}) => VPNServer.fromJson({
  'id': id,
  'name': id,
  'countryCode': country,
  'city': city,
  'available': available,
  'ping': 40,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final de = _server('de1', 'DE', city: 'Frankfurt');
  final nl = _server('nl1', 'NL', city: 'Amsterdam');
  final fi = _server('fi1', 'FI', city: 'Helsinki');
  final se = _server('se1', 'SE', city: 'Stockholm');
  final down = _server('pl1', 'PL', city: 'Warsaw', available: false);
  final all = [de, nl, fi, se, down];

  late _MemoryKv kv;
  late ColituServerShortcuts store;
  final original = ColituServerShortcuts.instance;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await ColituLoc.I.setLanguage('tr', persist: false);
    kv = _MemoryKv();
    store = ColituServerShortcuts(store: kv);
    ColituServerShortcuts.instance = store;
  });

  tearDown(() => ColituServerShortcuts.instance = original);

  group('store', () {
    test(
      'keeps the last three servers, newest first, without repeats',
      () async {
        await store.recordConnected(de);
        await store.recordConnected(nl);
        await store.recordConnected(fi);
        await store.recordConnected(nl);
        await store.recordConnected(se);
        expect(store.recentKeys, ['se1', 'nl1', 'fi1']);
        expect(jsonDecode(kv.map['colituRecentServers']!), [
          'se1',
          'nl1',
          'fi1',
        ]);
      },
    );

    test('favourites toggle and survive a restart', () async {
      await store.toggleFavorite(de);
      await store.toggleFavorite(fi);
      expect(store.isFavorite(de), isTrue);
      await store.toggleFavorite(de);
      expect(store.isFavorite(de), isFalse);

      final again = ColituServerShortcuts(store: kv);
      await again.load();
      expect(again.favoriteKeys, ['fi1']);
    });

    test('a server that left the list is not shown', () async {
      await store.toggleFavorite(de);
      await store.recordConnected(nl);
      final remaining = [fi, se];
      expect(store.favorites(remaining), isEmpty);
      expect(store.recents(remaining), isEmpty);
      expect(store.favorites(all).single.id, 'de1');
    });

    test(
      'home buttons: favourites first, no duplicates, at most three',
      () async {
        await store.toggleFavorite(fi);
        await store.recordConnected(de);
        await store.recordConnected(nl);
        await store.recordConnected(fi);
        await store.toggleFavorite(down);
        final buttons = store.homeButtons(all);
        expect(buttons.map((s) => s.id), ['fi1', 'nl1', 'de1']);
        // The server already chosen is left out.
        expect(
          store.homeButtons(all, except: fi.selectionKey).map((s) => s.id),
          ['nl1', 'de1'],
        );
      },
    );

    test('broken stored data reads as empty', () async {
      kv.map['colituFavoriteServers'] = '{not json';
      kv.map['colituRecentServers'] = '[1, "de1", "de1"]';
      await store.load();
      expect(store.favoriteKeys, isEmpty);
      expect(store.recentKeys, ['de1']);
    });
  });

  group('screens', () {
    Future<ColituConnectionController> pump(
      WidgetTester tester,
      Widget Function(ColituConnectionController c) page, {
      double textScale = 1,
    }) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = ColituConnectionController()
        ..loading = false
        ..servers = all;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ColituTheme.dark,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(393, 852),
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(body: page(c)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      return c;
    }

    testWidgets('locations: star adds a favourite section; labels are spoken', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, (c) => LocationsTab(controller: c));
      expect(find.text('FAVORİLER'), findsNothing);
      // The field's name comes first, then its placeholder.
      expect(find.bySemanticsLabel(RegExp('^Sunucu ara')), findsOneWidget);
      expect(find.bySemanticsLabel('Favorilere ekle'), findsWidgets);

      final star = find.byKey(ValueKey('star.${nl.selectionKey}')).first;
      expect(tester.getSize(star).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(star).height, greaterThanOrEqualTo(44));
      await tester.tap(star);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('FAVORİLER'), findsOneWidget);
      expect(find.bySemanticsLabel('Favorilerden çıkar'), findsWidgets);
      expect(store.isFavorite(nl), isTrue);

      // A server that cannot be reached says so.
      await tester.scrollUntilVisible(
        find.text('Ulaşılamıyor'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Ulaşılamıyor'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('locations: recent servers have their own section', (
      tester,
    ) async {
      await store.recordConnected(fi);
      await pump(tester, (c) => LocationsTab(controller: c));
      expect(find.text('SON KULLANILANLAR'), findsOneWidget);
      expect(
        find.byKey(ValueKey('shortcut.${fi.selectionKey}')),
        findsOneWidget,
      );
    });

    testWidgets('home: quick buttons switch the server in one tap', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await store.recordConnected(nl);
      await store.toggleFavorite(de);
      var opened = 0;
      final c = await pump(
        tester,
        (c) => HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () => opened++,
          onOpenPlan: () {},
        ),
      );
      expect(find.byKey(const ValueKey('quickServers')), findsOneWidget);
      expect(find.bySemanticsLabel('Frankfurt sunucusuna geç'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('quickServer.${de.selectionKey}')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.selectedServer?.id, 'de1');
      expect(c.autoSelection, isFalse);

      // The whole location card opens the locations; no separate button.
      expect(find.text('Sunucuyu değiştir'), findsNothing);
      expect(find.byIcon(CupertinoIcons.chevron_right), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('locationCard')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opened, 1);
      expect(find.byKey(const ValueKey('quickSettings')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('home: no recents or favourites, no quick buttons', (
      tester,
    ) async {
      await pump(
        tester,
        (c) => HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () {},
        ),
      );
      expect(find.byKey(const ValueKey('quickServers')), findsNothing);
    });

    testWidgets('home: free plan opens the plan tab with Go Premium', (
      tester,
    ) async {
      final before = AppSession.instance.currentUser;
      addTearDown(() => AppSession.instance.currentUser = before);
      AppSession.instance.currentUser = ColituUser(
        id: 'u2',
        email: 'a@example.com',
        subscriptionStatus: 'ACTIVE',
        plan: 'free',
      );
      var plan = 0;
      await pump(
        tester,
        (c) => HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () => plan++,
        ),
      );
      await tester.ensureVisible(find.text('Premium’a geç'));
      await tester.tap(find.text('Premium’a geç'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(plan, 1);
    });

    testWidgets('large text: card titles wrap instead of overflowing', (
      tester,
    ) async {
      await store.toggleFavorite(de);
      await pump(
        tester,
        (c) => HomeTab(
          controller: c,
          onToggle: () async {},
          onChangeLocation: () {},
          onOpenPlan: () {},
        ),
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      await pump(tester, (c) => LocationsTab(controller: c), textScale: 1.3);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('tab bar shows the name of the open tab only', (tester) async {
    var picked = -1;
    await tester.pumpWidget(
      MaterialApp(
        theme: ColituTheme.dark,
        home: Scaffold(
          bottomNavigationBar: ColituNavBar(
            items: const [
              ColituNavItem(
                icon: CupertinoIcons.house_fill,
                label: 'Ana sayfa',
              ),
              ColituNavItem(icon: CupertinoIcons.globe, label: 'Konumlar'),
              ColituNavItem(icon: CupertinoIcons.star_fill, label: 'Paket'),
              ColituNavItem(
                icon: CupertinoIcons.chat_bubble_text_fill,
                label: 'Destek',
              ),
              ColituNavItem(icon: CupertinoIcons.person_fill, label: 'Hesap'),
            ],
            index: 1,
            onChanged: (i) => picked = i,
          ),
        ),
      ),
    );
    expect(find.text('Konumlar'), findsOneWidget);
    expect(find.text('Ana sayfa'), findsNothing);
    expect(find.byIcon(CupertinoIcons.gift_fill), findsNothing);
    await tester.tap(find.byIcon(CupertinoIcons.star_fill));
    expect(picked, 2);
  });

  test('a plan more than ten years away has no end date', () {
    ColituClock.fix(() => DateTime(2026, 10, 27));
    addTearDown(() => ColituClock.fix(null));
    return ColituLoc.I.setLanguage('tr', persist: false).then((_) {
      expect(planDateOf(DateTime(2040, 1, 1)), 'Süresiz');
      expect(planLeftOf(DateTime(2040, 1, 1)), 'Süresiz');
      expect(planDateOf(DateTime(2027, 1, 1)), isNot('Süresiz'));
    });
  });
}
