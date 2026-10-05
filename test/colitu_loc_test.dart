import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ColituLoc.I.setLanguage('en', persist: false);
  });

  test('every key has a non-empty Russian, Turkish and English string', () {
    for (final key in ColituLoc.keys) {
      final values = ColituLoc.valuesOf(key);
      expect(values, hasLength(3), reason: key);
      for (final value in values) {
        expect(value.trim(), isNotEmpty, reason: key);
      }
    }
  });

  test('placeholders match across languages', () {
    final placeholder = RegExp(r'\{(\w+)\}');
    for (final key in ColituLoc.keys) {
      final values = ColituLoc.valuesOf(key);
      final expected = placeholder
          .allMatches(values[2])
          .map((m) => m.group(1))
          .toSet();
      for (final value in values) {
        final found = placeholder.allMatches(value).map((m) => m.group(1)).toSet();
        expect(found, expected, reason: key);
      }
    }
  });

  test('unknown keys fall back to the key and normalize rejects junk', () {
    expect(ColituLoc.I['nope.missing'], 'nope.missing');
    expect(ColituLoc.normalize('TR'), 'tr');
    expect(ColituLoc.normalize('de'), ColituLoc.defaultLanguage());
  });

  test('Russian plural forms', () async {
    await ColituLoc.I.setLanguage('ru', persist: false);
    final loc = ColituLoc.I;
    expect(loc.count('day', 1), '1 день');
    expect(loc.count('day', 3), '3 дня');
    expect(loc.count('day', 5), '5 дней');
    expect(loc.count('day', 11), '11 дней');
    expect(loc.count('day', 21), '21 день');
    expect(loc.count('device', 2), '2 устройства');
  });

  test('English and Turkish plural forms', () async {
    final loc = ColituLoc.I;
    expect(loc.count('device', 1), '1 device');
    expect(loc.count('device', 4), '4 devices');
    await loc.setLanguage('tr', persist: false);
    expect(loc.count('device', 4), '4 cihaz');
  });

  test('money, percent and bytes formatting', () async {
    final loc = ColituLoc.I;
    expect(loc.money(129000), '1,290 ₽');
    expect(loc.money(12950), '129.50 ₽');
    expect(loc.money(-500), '−5 ₽');
    expect(loc.percent(250), '2.5');
    expect(loc.percent(300), '3');
    expect(loc.bytes(1536), '1.5 KB');
    await loc.setLanguage('ru', persist: false);
    expect(loc.money(129000), '1 290 ₽');
    expect(loc.bytes(3 * 1024 * 1024), '3 МБ');
  });

  test('dates and country names follow the language', () async {
    final loc = ColituLoc.I;
    final date = DateTime(2026, 9, 24, 12);
    expect(loc.date(date), '24 September 2026');
    expect(loc.countryName('ee'), 'Estonia');
    await loc.setLanguage('tr', persist: false);
    expect(loc.date(date), '24 Eylül 2026');
    expect(loc.countryName('EE'), 'Estonya');
    expect(loc.countryName('ZZ'), 'ZZ');
  });

  test('format replaces named placeholders', () {
    expect(
      ColituLoc.I.format('home.sub.on', {'server': 'Estonia'}),
      'Your traffic is encrypted and routed through Estonia.',
    );
  });
}
