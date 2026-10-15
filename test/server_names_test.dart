import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/l10n/server_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('display names: country and suffix in the asked language', () {
    expect(
      ColituServerNames.displayName('Letonya (Köprü)', language: 'en'),
      'Latvia (Bridge)',
    );
    expect(
      ColituServerNames.displayName('Letonya (Köprü)', language: 'ru'),
      'Латвия (Мост)',
    );
    expect(
      ColituServerNames.displayName('Letonya (Köprü)', language: 'tr'),
      'Letonya (Köprü)',
    );
    expect(ColituServerNames.displayName('Almanya', language: 'en'), 'Germany');
    expect(
      ColituServerNames.displayName('ALMANYA', language: 'ru'),
      'Германия',
    );
    // The country code itself, and a suffix the table does not know.
    expect(
      ColituServerNames.displayName(
        'LV (Test)',
        countryCode: 'LV',
        language: 'en',
      ),
      'Latvia (Test)',
    );
    expect(
      ColituServerNames.displayName('UK', language: 'tr'),
      'Birleşik Krallık',
    );
  });

  test('cities: case- and diacritic-insensitive, aliases too', () {
    expect(ColituServerNames.city('Londra', language: 'en'), 'London');
    expect(ColituServerNames.city('londra', language: 'ru'), 'Лондон');
    expect(ColituServerNames.city('Varşova', language: 'en'), 'Warsaw');
    expect(ColituServerNames.city('Varsova', language: 'ru'), 'Варшава');
    expect(ColituServerNames.city('Almatı', language: 'en'), 'Almaty');
    expect(ColituServerNames.city('Sao Paulo', language: 'tr'), 'São Paulo');
    expect(ColituServerNames.city('Kyiv', language: 'ru'), 'Киев');
    expect(ColituServerNames.city('İstanbul', language: 'en'), 'Istanbul');
    expect(ColituServerNames.city('Лондон', language: 'tr'), 'Londra');
  });

  test('unknown text stays exactly as the panel sent it', () {
    for (final language in ColituLoc.languages) {
      expect(
        ColituServerNames.displayName(
          'Codex staging Docker node',
          language: language,
        ),
        'Codex staging Docker node',
      );
      expect(
        ColituServerNames.city('Codex staging Docker node', language: language),
        'Codex staging Docker node',
      );
      expect(
        ColituServerNames.route(
          'Codex staging Docker node',
          language: language,
        ),
        'Codex staging Docker node',
      );
    }
    expect(ColituServerNames.city('', language: 'en'), '');
    expect(ColituServerNames.city(null, language: 'en'), '');
  });

  test('multihop route names: each end', () {
    expect(
      ColituServerNames.route('Varşova → Frankfurt', language: 'en'),
      'Warsaw → Frankfurt',
    );
    expect(
      ColituServerNames.route('Helsinki → Almanya', language: 'ru'),
      'Хельсинки → Германия',
    );
  });

  test('follows the app language when none is given', () async {
    final loc = ColituLoc.I;
    final before = loc.language;
    await loc.setLanguage('en', persist: false);
    expect(ColituServerNames.city('Londra'), 'London');
    await loc.setLanguage('ru', persist: false);
    expect(ColituServerNames.city('Londra'), 'Лондон');
    await loc.setLanguage(before, persist: false);
  });
}
