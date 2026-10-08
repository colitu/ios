import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/server_groups.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/shell/locations_tab.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VPNServer _server(
  String id,
  String country, {
  String? city,
  int? ping,
  bool available = true,
  bool recommended = false,
}) => VPNServer.fromJson({
  'id': id,
  'name': id,
  'countryCode': country,
  'city': city,
  'available': available,
  'recommended': recommended,
  'ping': ping,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ColituLoc.I.setLanguage('en', persist: false);
  });

  final de1 = _server('de1', 'DE', city: 'Frankfurt', ping: 50);
  final nl = _server('nl1', 'NL', city: 'Amsterdam', ping: 20);
  final de2 = _server('de2', 'DE', city: 'Berlin', ping: 35);
  final ee = _server('ee1', 'EE', city: 'Tallinn', ping: 60, recommended: true);
  final all = [de1, nl, de2, ee];

  group('groupServersByCountry', () {
    test('groups by country code, keeping first-seen and in-group order', () {
      final groups = groupServersByCountry(all);
      expect(groups.map((g) => g.key), ['DE', 'NL', 'EE']);
      expect(groups[0].servers, [de1, de2]);
      expect(groups[0].isSingle, isFalse);
    });

    test('a country with one server stays a single (flat) row', () {
      final groups = groupServersByCountry(all);
      expect(groups[1].isSingle, isTrue);
      expect(groups[1].servers.single, nl);
      expect(groups[2].isSingle, isTrue);
    });

    test('a search (flat) never groups', () {
      final groups = groupServersByCountry(all, flat: true);
      expect(groups, hasLength(4));
      expect(groups.every((g) => g.isSingle), isTrue);
      expect(groups.expand((g) => g.servers), all);
    });

    test('the order of the sorted input decides countries and cities', () {
      final byPing = [...all]
        ..sort((a, b) => (a.ping ?? 0).compareTo(b.ping ?? 0));
      final groups = groupServersByCountry(byPing);
      // NL(20), DE(35 first), EE(60); inside DE the 35 ms city comes first.
      expect(groups.map((g) => g.key), ['NL', 'DE', 'EE']);
      expect(groups[1].servers, [de2, de1]);
    });

    test('best ping ignores servers that cannot be picked', () {
      final off = _server(
        'de3',
        'DE',
        city: 'Munich',
        ping: 5,
        available: false,
      );
      final group = groupServersByCountry([de1, de2, off]).single;
      expect(group.bestPing((s) => s.ping), 35);
      expect(
        groupServersByCountry([
          off,
          _server('de4', 'DE'),
        ]).single.bestPing((s) => s.ping),
        isNull,
      );
    });
  });

  group('isGroupExpanded', () {
    test('starts open only for the group with the selected server', () {
      final groups = groupServersByCountry(all);
      expect(isGroupExpanded(groups[0], selectedKey: 'de2'), isTrue);
      expect(isGroupExpanded(groups[0], selectedKey: 'nl1'), isFalse);
      expect(isGroupExpanded(groups[0], selectedKey: null), isFalse);
    });

    test('the user choice wins over the selection', () {
      final de = groupServersByCountry(all).first;
      expect(
        isGroupExpanded(de, selectedKey: 'de1', overrides: {'DE': false}),
        isFalse,
      );
      expect(
        isGroupExpanded(de, selectedKey: null, overrides: {'DE': true}),
        isTrue,
      );
    });
  });

  test('city label: the city field, else the usual name', () {
    expect(serverCityLabel(de1), 'Frankfurt');
    expect(serverCityLabel(_server('x', 'DE', city: '  ')), isNot(isEmpty));
    expect(serverCityLabel(_server('x', 'DE', city: '  Köln ')), 'Köln');
  });

  test('location count noun in three languages', () async {
    final loc = ColituLoc.I;
    expect(loc.count('locationCount', 3), '3 locations');
    await loc.setLanguage('tr', persist: false);
    expect(loc.count('locationCount', 3), '3 konum');
    await loc.setLanguage('ru', persist: false);
    expect(loc.count('locationCount', 2), '2 локации');
    expect(loc.count('locationCount', 5), '5 локаций');
  });

  group('LocationsTab', () {
    Future<ColituConnectionController> pump(
      WidgetTester tester, {
      VPNServer? selected,
    }) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = ColituConnectionController()
        ..loading = false
        ..servers = all;
      if (selected != null) {
        c
          ..autoSelection = false
          ..selectedServer = selected;
      }
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ColituTheme.dark,
          home: Scaffold(body: LocationsTab(controller: c)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      return c;
    }

    testWidgets('multi-server country is a collapsed header; tap expands', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('2 locations'), findsOneWidget);
      expect(find.text('Berlin'), findsNothing);
      expect(find.text('Frankfurt'), findsNothing);

      await tester.tap(find.text('2 locations'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Berlin'), findsOneWidget);
      expect(find.text('Frankfurt'), findsOneWidget);

      await tester.tap(find.text('2 locations'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Berlin'), findsNothing);
    });

    testWidgets('the group of the selected server starts expanded', (
      tester,
    ) async {
      await pump(tester, selected: de2);
      expect(find.text('Berlin'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.checkmark_alt), findsOneWidget);
    });

    testWidgets('a search lists matches flat', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'ber');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('2 locations'), findsNothing);
      expect(find.textContaining('Berlin'), findsWidgets);
    });
  });
}
