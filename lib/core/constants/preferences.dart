import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PreferencesKey {
  final _prefs = SharedPreferencesAsync();

  static final PreferencesKey _singleton = PreferencesKey._internal();

  factory PreferencesKey() => _singleton;

  PreferencesKey._internal();

  static const _privacyAccepted = "privacyAccepted02";

  Future<bool> readPrivacyAccepted() async {
    final value = await _prefs.getBool(_privacyAccepted);
    if (value == null) {
      return false;
    }
    return value;
  }

  Future<void> savePrivacyAccepted(bool value) async {
    await _prefs.setBool(_privacyAccepted, value);
  }

  static const _firstRun = "firstRun01";

  Future<bool> readFirstRun() async {
    final value = await _prefs.getBool(_firstRun);
    if (value == null) {
      return true;
    }
    return value;
  }

  Future<void> saveFirstRun(bool value) async {
    await _prefs.setBool(_firstRun, value);
  }

  static const _localSubscriptionExpanded = "localSubscriptionExpanded";

  Future<bool> readLocalSubscriptionExpanded() async {
    final value = await _prefs.getBool(_localSubscriptionExpanded);
    if (value == null) {
      return true;
    }
    return value;
  }

  Future<void> saveLocalSubscriptionExpanded(bool value) async {
    await _prefs.setBool(_localSubscriptionExpanded, value);
  }

  static const _runningConfigId = "runningConfigId";

  Future<int> readRunningConfigId() async {
    final value = await _prefs.getInt(_runningConfigId);
    if (value == null) {
      return DBConstants.defaultId;
    }
    return value;
  }

  Future<void> saveRunningConfigId(int value) async {
    await _prefs.setInt(_runningConfigId, value);
  }

  static const _lastConfigId = "lastConfigId";

  Future<int> readLastConfigId() async {
    final value = await _prefs.getInt(_lastConfigId);
    if (value == null) {
      return DBConstants.defaultId;
    }
    return value;
  }

  Future<void> saveLastConfigId(int value) async {
    await _prefs.setInt(_lastConfigId, value);
  }

  static const _vpnStartTimestamp = "vpnStartTimestamp";

  Future<DateTime> readVpnStartTimestamp() async {
    final value = await _prefs.getInt(_vpnStartTimestamp);
    if (value == null) {
      return DateTime.now();
    }
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }

  Future<void> saveVpnStartTimestamp() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _prefs.setInt(_vpnStartTimestamp, timestamp);
  }

  static const _pingState = "pingState";

  Future<Map<String, dynamic>?> readPingState() async {
    final value = await _prefs.getString(_pingState);
    if (value != null) {
      return JsonTool.decodeBase64ToJson(value);
    }
    return null;
  }

  Future<void> savePingState(Map<String, dynamic> value) async {
    final text = JsonTool.encodeJsonToBase64(value);
    await _prefs.setString(_pingState, text);
  }

  static const _xraySettingId = "xraySettingId";

  Future<int> readXraySettingId() async {
    final value = await _prefs.getInt(_xraySettingId);
    if (value == null) {
      return DBConstants.defaultId;
    }
    return value;
  }

  Future<void> saveXraySettingId(int value) async {
    await _prefs.setInt(_xraySettingId, value);
  }

  static const _xraySettingSimple = "xraySettingSimple";

  Future<Map<String, dynamic>?> readXraySettingSimple() async {
    final value = await _prefs.getString(_xraySettingSimple);
    if (value != null) {
      return JsonTool.decodeBase64ToJson(value);
    }
    return null;
  }

  Future<void> saveXraySettingSimple(Map<String, dynamic> value) async {
    final text = JsonTool.encodeJsonToBase64(value);
    await _prefs.setString(_xraySettingSimple, text);
  }

  static const _tunSetting = "tunSetting";

  Future<Map<String, dynamic>?> readTunSetting() async {
    final value = await _prefs.getString(_tunSetting);
    if (value != null) {
      return JsonTool.decodeBase64ToJson(value);
    }
    return null;
  }

  Future<void> saveTunSetting(Map<String, dynamic> value) async {
    final text = JsonTool.encodeJsonToBase64(value);
    await _prefs.setString(_tunSetting, text);
  }

  static const _queryAllPackagesAccepted = "queryAllPackagesAccepted";

  Future<bool> readQueryAllPackagesAccepted() async {
    final value = await _prefs.getBool(_queryAllPackagesAccepted);
    if (value == null) {
      return false;
    }
    return value;
  }

  Future<void> saveQueryAllPackagesAccepted(bool value) async {
    await _prefs.setBool(_queryAllPackagesAccepted, value);
  }

  static const _hideDockIcon = "hideIconInDock";

  Future<bool> readHideDockIcon() async {
    final value = await _prefs.getBool(_hideDockIcon);
    if (value == null) {
      return false;
    }
    return value;
  }

  Future<void> saveHideDockIcon(bool value) async {
    await _prefs.setBool(_hideDockIcon, value);
  }

  static const _subUpdate = "subUpdate";

  Future<Map<String, dynamic>?> readSubUpdate() async {
    final value = await _prefs.getString(_subUpdate);
    if (value != null) {
      return JsonTool.decodeBase64ToJson(value);
    }
    return null;
  }

  Future<void> saveSubUpdate(Map<String, dynamic> value) async {
    final text = JsonTool.encodeJsonToBase64(value);
    await _prefs.setString(_subUpdate, text);
  }

  static const _themeCode = "themeCode";

  Future<String?> readThemeCode() async {
    return _prefs.getString(_themeCode);
  }

  Future<void> saveThemeCode(String value) async {
    await _prefs.setString(_themeCode, value);
  }

  static const _languageCode = "languageCode";

  Future<String?> readLanguageCode() async {
    return _prefs.getString(_languageCode);
  }

  Future<void> saveLanguageCode(String value) async {
    await _prefs.setString(_languageCode, value);
  }

  static const _colituSelectedServerId = "colituSelectedServerId";

  Future<String?> readColituSelectedServerId() async {
    return _prefs.getString(_colituSelectedServerId);
  }

  Future<void> saveColituSelectedServerId(String value) async {
    await _prefs.setString(_colituSelectedServerId, value);
  }

  Future<void> clearColituSelectedServerId() async {
    await _prefs.remove(_colituSelectedServerId);
  }

  static const _colituRuntimeConfigId = "colituRuntimeConfigId";

  Future<int> readColituRuntimeConfigId() async {
    final value = await _prefs.getInt(_colituRuntimeConfigId);
    if (value == null) {
      return DBConstants.defaultId;
    }
    return value;
  }

  Future<void> saveColituRuntimeConfigId(int value) async {
    await _prefs.setInt(_colituRuntimeConfigId, value);
  }

  Future<void> clearColituRuntimeConfigId() async {
    await _prefs.remove(_colituRuntimeConfigId);
  }

  static const _colituKillSwitchEnabled = "colituKillSwitchEnabled";

  /// Always-on protection (iOS on-demand) is on unless the user turned it
  /// off: iOS then restarts the tunnel by itself if it is ever stopped.
  Future<bool> readColituKillSwitchEnabled() async {
    return await _prefs.getBool(_colituKillSwitchEnabled) ?? true;
  }

  Future<void> saveColituKillSwitchEnabled(bool value) async {
    await _prefs.setBool(_colituKillSwitchEnabled, value);
  }

  static const _colituLanguage = "colituLanguage";

  Future<String?> readColituLanguage() async {
    return _prefs.getString(_colituLanguage);
  }

  Future<void> saveColituLanguage(String value) async {
    await _prefs.setString(_colituLanguage, value);
  }

  static const _colituServerPings = "colituServerPings";

  /// Last measured ping per server, as JSON {"selectionKey": ms}.
  Future<String?> readColituServerPings() async {
    return _prefs.getString(_colituServerPings);
  }

  Future<void> saveColituServerPings(String value) async {
    await _prefs.setString(_colituServerPings, value);
  }

  static const _colituLastDropTs = "colituLastDropTs";

  Future<int> readColituLastDropTs() async {
    return await _prefs.getInt(_colituLastDropTs) ?? 0;
  }

  Future<void> saveColituLastDropTs(int value) async {
    await _prefs.setInt(_colituLastDropTs, value);
  }

  static const _colituOnboardingSeen = "colituOnboardingSeen";

  Future<bool> readColituOnboardingSeen() async {
    return await _prefs.getBool(_colituOnboardingSeen) ?? false;
  }

  Future<void> saveColituOnboardingSeen(bool value) async {
    await _prefs.setBool(_colituOnboardingSeen, value);
  }

  static const _colituAutoConnect = "colituAutoConnect";

  Future<bool> readColituAutoConnect() async {
    return await _prefs.getBool(_colituAutoConnect) ?? true;
  }

  Future<void> saveColituAutoConnect(bool value) async {
    await _prefs.setBool(_colituAutoConnect, value);
  }

  static const _colituAdBlock = "colituAdBlock";

  /// Ad and tracker blocking through Colitu's DNS servers; off unless the
  /// user turns it on.
  Future<bool> readColituAdBlock() async {
    return await _prefs.getBool(_colituAdBlock) ?? false;
  }

  Future<void> saveColituAdBlock(bool value) async {
    await _prefs.setBool(_colituAdBlock, value);
  }

  static const _colituPrivacyMode = "colituPrivacyMode";

  /// Privacy mode: Russian addresses go through the tunnel too, instead of
  /// leaving it directly on a server outside Russia. Off by default.
  Future<bool> readColituPrivacyMode() async {
    return await _prefs.getBool(_colituPrivacyMode) ?? false;
  }

  Future<void> saveColituPrivacyMode(bool value) async {
    await _prefs.setBool(_colituPrivacyMode, value);
  }

  static const _colituRuDirectNoticeShown = "colituRuDirectNoticeShown";

  /// Whether the one-time "Russian sites go outside the VPN" notice was shown.
  Future<bool> readColituRuDirectNoticeShown() async {
    return await _prefs.getBool(_colituRuDirectNoticeShown) ?? false;
  }

  Future<void> saveColituRuDirectNoticeShown(bool value) async {
    await _prefs.setBool(_colituRuDirectNoticeShown, value);
  }

  static const _colituStrictKillSwitch = "colituStrictKillSwitch";

  /// Strict kill switch (iOS includeAllNetworks): no traffic leaves the
  /// device outside the tunnel, not even while it reconnects. Off by
  /// default because iOS then also blocks captive-portal sign-in pages and
  /// can hold App Store updates of Colitu while the tunnel is down.
  Future<bool> readColituStrictKillSwitch() async {
    return await _prefs.getBool(_colituStrictKillSwitch) ?? false;
  }

  Future<void> saveColituStrictKillSwitch(bool value) async {
    await _prefs.setBool(_colituStrictKillSwitch, value);
  }

  static const _colituSplitTunnel = "colituSplitTunnel";

  /// Split tunneling as JSON {"mode", "domains", "ips"}; null when never set.
  Future<String?> readColituSplitTunnel() async {
    return _prefs.getString(_colituSplitTunnel);
  }

  Future<void> saveColituSplitTunnel(String value) async {
    await _prefs.setString(_colituSplitTunnel, value);
  }

  static const _colituTrialBannerDismissed = "colituTrialBannerDismissed";

  /// Day ("2026-10-06") the trial-end banner was last dismissed.
  Future<String?> readColituTrialBannerDismissed() async {
    return _prefs.getString(_colituTrialBannerDismissed);
  }

  Future<void> saveColituTrialBannerDismissed(String value) async {
    await _prefs.setString(_colituTrialBannerDismissed, value);
  }
}
