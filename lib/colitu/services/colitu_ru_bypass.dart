/// Russian sites and apps (geoip:RU) leave the tunnel directly, as on Android
/// and Windows, except when the server itself is in Russia: then they go
/// through it, so Russians abroad reach banks, Gosuslugi and Russian TV with
/// a Russian address.
///
/// Privacy mode turns the exception off: every connection goes through the
/// tunnel, whatever the server's country.
class ColituRuBypass {
  ColituRuBypass._();

  /// Country (ISO code) of the server the next tunnel connects to; set by the
  /// connection controller before the core configuration is written.
  static String? serverCountry;

  /// The user's privacy mode setting (stored as `colituPrivacyMode`); read
  /// from the preferences right before the core configuration is written.
  static bool privacyMode = false;

  static bool get applies => appliesTo(serverCountry, privacyMode);

  /// Help page listing what goes outside the tunnel (`ru`, `tr` or `en`).
  static String docsUrl(String language) =>
      'https://docs.colitu.com/$language/split-tunneling';

  /// Whether Russian addresses leave the tunnel directly for a server in
  /// [country]. The configuration and the connected-screen chip both ask this.
  static bool appliesTo(String? country, bool privacyMode) =>
      !privacyMode && (country ?? '').trim().toUpperCase() != 'RU';

  /// Domain and IP matchers that select Russian destinations
  /// (case-insensitive): geoip:RU, the Russian geosite lists and `.ru`.
  static bool isRussianMatcher(Object? value) {
    if (value is! String) return false;
    final matcher = value.trim().toLowerCase();
    if (matcher == 'geoip:ru') return true;
    if (matcher.startsWith('geosite:')) {
      final code = matcher.substring('geosite:'.length).split('@').first;
      return code == 'yandex' || code == 'mailru' || code.endsWith('-ru');
    }
    return const {
      r'regexp:.ru$',
      r'regexp:\.ru$',
      'domain:ru',
      'domain:su',
      'domain:xn--p1ai',
    }.contains(matcher);
  }

  /// A direct rule's [domain] and [ip] lists without Russian matchers, or
  /// null when the rule only matched Russian destinations and must go. Used
  /// in privacy mode, so no rule from any source sends Russian traffic
  /// outside the tunnel. The given lists are not changed.
  static ({List<T>? domain, List<T>? ip})? withoutRussian<T>(
    List<T>? domain,
    List<T>? ip,
  ) {
    List<T>? keep(List<T>? values) =>
        values?.where((value) => !isRussianMatcher(value)).toList();
    final keptDomain = keep(domain);
    final keptIp = keep(ip);
    if ((domain?.isNotEmpty ?? false) && keptDomain!.isEmpty) return null;
    if ((ip?.isNotEmpty ?? false) && keptIp!.isEmpty) return null;
    return (domain: keptDomain, ip: keptIp);
  }
}
