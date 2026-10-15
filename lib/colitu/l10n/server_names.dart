import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';

/// Server names in the app language.
///
/// The panel sends a node's display name and city in Turkish ("Almanya",
/// "Londra", "Letonya (Köprü)"). They are matched case- and
/// diacritic-insensitively against the Turkish, English and Russian names
/// (and a few aliases) and shown in the app language; text that matches
/// nothing stays exactly as the panel sent it. The tables are shared by all
/// Colitu apps (`_repo_disi_dosyalar/sunucu-adlari-ceviri.json`, 2026-10-12);
/// country names come from [ColituLoc]'s country table.
abstract final class ColituServerNames {
  /// [ru, tr, en] like [ColituLoc.languages], then aliases.
  static const _cities = <List<String>>[
    ['Тирана', 'Tiran', 'Tirana'],
    ['Мельбурн', 'Melbourne', 'Melbourne'],
    ['Сан-Паулу', 'São Paulo', 'São Paulo', 'Sao Paulo'],
    ['Франкфурт', 'Frankfurt', 'Frankfurt'],
    ['Берлин', 'Berlin', 'Berlin'],
    ['Таллин', 'Tallinn', 'Tallinn'],
    ['Тарту', 'Tartu', 'Tartu'],
    ['Мадрид', 'Madrid', 'Madrid'],
    ['Хельсинки', 'Helsinki', 'Helsinki'],
    ['Париж', 'Paris', 'Paris'],
    ['Лондон', 'Londra', 'London'],
    ['Ковентри', 'Coventry', 'Coventry'],
    ['Салоники', 'Selanik', 'Thessaloniki'],
    ['Тель-Авив', 'Tel Aviv', 'Tel Aviv', 'Tel-Aviv'],
    ['Токио', 'Tokyo', 'Tokyo'],
    ['Алматы', 'Almatı', 'Almaty'],
    ['Вильнюс', 'Vilnius', 'Vilnius'],
    ['Рига', 'Riga', 'Riga'],
    ['Керкраде', 'Kerkrade', 'Kerkrade'],
    ['Дронтен', 'Dronten', 'Dronten'],
    ['Варшава', 'Varşova', 'Warsaw'],
    ['Москва', 'Moskova', 'Moscow'],
    ['Сингапур', 'Singapur', 'Singapore'],
    ['Бурса', 'Bursa', 'Bursa'],
    ['Киев', 'Kiev', 'Kyiv', 'Kyiv'],
    ['Даллас', 'Dallas', 'Dallas'],
    ['Амстердам', 'Amsterdam', 'Amsterdam'],
    ['Стамбул', 'İstanbul', 'Istanbul'],
    ['Анкара', 'Ankara', 'Ankara'],
    ['Стокгольм', 'Stockholm', 'Stockholm'],
    ['Вена', 'Viyana', 'Vienna'],
    ['Цюрих', 'Zürih', 'Zurich'],
    ['Прага', 'Prag', 'Prague'],
    ['Бухарест', 'Bükreş', 'Bucharest'],
    ['София', 'Sofya', 'Sofia'],
    ['Будапешт', 'Budapeşte', 'Budapest'],
    ['Афины', 'Atina', 'Athens'],
    ['Белград', 'Belgrad', 'Belgrade'],
    ['Ереван', 'Erivan', 'Yerevan'],
    ['Тбилиси', 'Tiflis', 'Tbilisi'],
    ['Баку', 'Bakü', 'Baku'],
    ['Дубай', 'Dubai', 'Dubai'],
    ['Копенгаген', 'Kopenhag', 'Copenhagen'],
    ['Осло', 'Oslo', 'Oslo'],
    ['Милан', 'Milano', 'Milan'],
    ['Рим', 'Roma', 'Rome'],
    ['Мюнхен', 'Münih', 'Munich'],
    ['Дюссельдорф', 'Düsseldorf', 'Düsseldorf'],
    ['Нюрнберг', 'Nürnberg', 'Nuremberg'],
    ['Нью-Йорк', 'New York', 'New York'],
    ['Лос-Анджелес', 'Los Angeles', 'Los Angeles'],
    ['Майами', 'Miami', 'Miami'],
    ['Торонто', 'Toronto', 'Toronto'],
    ['Монреаль', 'Montreal', 'Montreal'],
    ['Сидней', 'Sidney', 'Sydney'],
    ['Гонконг', 'Hong Kong', 'Hong Kong'],
    ['Сеул', 'Seul', 'Seoul'],
  ];

  /// Suffixes in "(...)" after a country name, [ru, tr, en].
  static const _suffixes = <List<String>>[
    ['Мост', 'Köprü', 'Bridge'],
  ];

  static final Map<String, List<String>> _cityIndex = _index(_cities);
  static final Map<String, List<String>> _suffixIndex = _index(_suffixes);

  static Map<String, List<String>> _index(List<List<String>> rows) => {
    for (final row in rows)
      for (final name in row) normalize(name): row,
  };

  static const _folds = {
    'ı': 'i',
    'ş': 's',
    'ğ': 'g',
    'ü': 'u',
    'ö': 'o',
    'ç': 'c',
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'õ': 'o',
    'ø': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ñ': 'n',
    'ß': 'ss',
    'ё': 'е',
    'й': 'и',
  };

  /// Lower case without diacritics and with single spaces: the key names
  /// are compared by.
  static String normalize(String text) {
    final lower = text.trim().toLowerCase();
    final out = StringBuffer();
    for (final rune in lower.runes) {
      // The combining dot "İ".toLowerCase() leaves behind, and other
      // combining marks.
      if (rune >= 0x0300 && rune <= 0x036f) continue;
      final char = String.fromCharCode(rune);
      out.write(_folds[char] ?? char);
    }
    return out.toString().replaceAll(RegExp(r'\s+'), ' ');
  }

  static int _slot(String? language) {
    final index = ColituLoc.languages.indexOf(language ?? ColituLoc.I.language);
    return index < 0 ? ColituLoc.languages.indexOf('en') : index;
  }

  /// A city in [language] (the app language by default); unknown text as
  /// it is.
  static String city(String? raw, {String? language}) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return text;
    final row = _cityIndex[normalize(text)];
    return row == null ? text : row[_slot(language)];
  }

  /// A display name: "Letonya (Köprü)" → "Latvia (Bridge)". The part before
  /// a trailing "(...)" is shown as the country name when it is
  /// [countryCode] or any known country name; the suffix is translated when
  /// known. Otherwise the text stays as it is (a city name is translated).
  static String displayName(
    String? raw, {
    String? countryCode,
    String? language,
  }) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return text;
    final match = RegExp(r'^(.*?)\s*\(([^()]*)\)$').firstMatch(text);
    final head = (match?.group(1) ?? text).trim();
    final suffix = match?.group(2)?.trim();
    final code = _countryCode(head, countryCode);
    String localizedHead;
    if (code != null) {
      localizedHead = ColituLoc.I.countryName(code, language: language);
    } else {
      final cityRow = _cityIndex[normalize(head)];
      if (cityRow == null && match == null) return text;
      localizedHead = cityRow == null ? head : cityRow[_slot(language)];
    }
    if (suffix == null) return localizedHead;
    if (head.isEmpty) return text;
    final suffixRow = _suffixIndex[normalize(suffix)];
    final localizedSuffix = suffixRow == null
        ? suffix
        : suffixRow[_slot(language)];
    return '$localizedHead ($localizedSuffix)';
  }

  /// A multihop route name, "Varşova → Frankfurt": each end as a city or a
  /// display name.
  static String route(String? raw, {String? language}) {
    final text = raw?.trim() ?? '';
    if (!text.contains('→')) return displayName(text, language: language);
    return text
        .split('→')
        .map((part) => displayName(part, language: language))
        .join(' → ');
  }

  static String? _countryCode(String name, String? countryCode) {
    if (name.isEmpty) return null;
    final code = countryCode?.trim().toUpperCase() ?? '';
    if (code.length == 2 && normalize(name) == normalize(code)) return code;
    if (name.length == 2 && ColituLoc.I.hasCountry(name)) {
      return name.toUpperCase();
    }
    return ColituLoc.I.countryCodeForName(name);
  }
}
