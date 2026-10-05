/// Russian sites and apps (geoip:RU) leave the tunnel directly, as on Android
/// and Windows, except when the server itself is in Russia: then they go
/// through it, so Russians abroad reach banks, Gosuslugi and Russian TV with
/// a Russian address.
class ColituRuBypass {
  ColituRuBypass._();

  /// Country (ISO code) of the server the next tunnel connects to; set by the
  /// connection controller before the core configuration is written.
  static String? serverCountry;

  static bool get applies => appliesTo(serverCountry);

  static bool appliesTo(String? country) =>
      (country ?? '').trim().toUpperCase() != 'RU';
}
