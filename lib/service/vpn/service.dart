import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duration/duration.dart';
import 'package:duration/locale.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:colitu_vpn/core/tools/platform.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/core/db/database/database.dart';
import 'package:colitu_vpn/core/db/database/enum.dart';
import 'package:colitu_vpn/core/network/client.dart';
import 'package:colitu_vpn/core/network/standard.dart';
import 'package:colitu_vpn/core/pigeon/flutter_api.dart';
import 'package:colitu_vpn/core/pigeon/host_api.dart';
import 'package:colitu_vpn/core/pigeon/messages.g.dart';
import 'package:colitu_vpn/core/pigeon/model.dart';
import 'package:colitu_vpn/core/tools/file.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:colitu_vpn/service/localizations/service.dart';
import 'package:colitu_vpn/core/tools/logger.dart';
import 'package:colitu_vpn/service/event_bus/service.dart';
import 'package:colitu_vpn/service/menu/tray/service.dart';
import 'package:colitu_vpn/service/notification/service.dart';
import 'package:colitu_vpn/core/pigeon/model_reader.dart';
import 'package:colitu_vpn/core/pigeon/model_writer.dart';
import 'package:colitu_vpn/service/ping/state.dart';
import 'package:colitu_vpn/service/toast/service.dart';
import 'package:colitu_vpn/service/tun_setting/state.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:colitu_vpn/service/xray/constants.dart';
import 'package:colitu_vpn/service/xray/json_writer.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_reader.dart';
import 'package:colitu_vpn/service/xray/raw/fix.dart';
import 'package:colitu_vpn/service/xray/setting/enum.dart';
import 'package:colitu_vpn/service/xray/setting/inbounds_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:colitu_vpn/service/xray/setting/state_reader.dart';
import 'package:colitu_vpn/service/xray/setting/state_writer.dart';

final class VpnService {
  static final VpnService _singleton = VpnService._internal();

  factory VpnService() => _singleton;

  VpnService._internal();

  //=================================
  var _lastConfigId = DBConstants.defaultId;
  var _nextStartId = DBConstants.defaultId;
  var _vpnRunning = false;
  var _stopRequestedWithoutRestart = false;

  bool get vpnRunning => _vpnRunning;

  Future<void> asyncInit() async {
    final eventBus = AppEventBus.instance;
    final savedRunningId = await PreferencesKey().readRunningConfigId();
    eventBus.updateRunningId(savedRunningId);

    _lastConfigId = await PreferencesKey().readLastConfigId();

    await _listenVpnStatus();

    await AppHostApi().checkVpnPermission();
  }

  void dispose() {
    _vpnStatusSubscription.cancel();
  }

  late StreamSubscription<VpnStatus> _vpnStatusSubscription;

  Future<void> _listenVpnStatus() async {
    ygLogger("_listenVpnStatus");
    _vpnStatusSubscription = AppFlutterApi().vpnStatusController.stream.listen(
      (status) => unawaited(_handleVpnStatus(status)),
      onError: (Object error, StackTrace stack) {
        debugPrint('VPN status stream failed: $error');
        debugPrint('$stack');
        AppEventBus.instance.updateVpnLoading(false);
      },
    );
    await AppHostApi().readVpnStatus();
  }

  Future<void> _handleVpnStatus(VpnStatus status) async {
    try {
      await _vpnStatusChanged(status);
    } catch (error, stack) {
      debugPrint('VPN status handling failed: $error');
      debugPrint('$stack');
      _nextStartId = DBConstants.defaultId;
      await _updateRunningId(DBConstants.defaultId);
      AppEventBus.instance.updateVpnLoading(false);
    }
  }

  Future<void> _vpnStatusChanged(VpnStatus status) async {
    final eventBus = AppEventBus.instance;
    switch (status) {
      case VpnStatus.disconnecting:
        if (_stopRequestedWithoutRestart &&
            _nextStartId == DBConstants.defaultId) {
          await _updateRunningId(DBConstants.defaultId);
          eventBus.updateVpnLoading(false);
        } else {
          eventBus.updateVpnLoading(true);
        }
        break;
      case VpnStatus.disconnected:
        final reconnectAfterUnexpectedExit =
            _vpnRunning &&
            !_stopRequestedWithoutRestart &&
            _lastConfigId != DBConstants.defaultId;
        _vpnRunning = false;
        if (reconnectAfterUnexpectedExit) {
          _nextStartId = _lastConfigId;
          await _updateRunningId(DBConstants.defaultId);
          eventBus.updateVpnLoading(true);
          await Future.delayed(const Duration(seconds: 2));
        }
        await _tryStartVpn();
        await TrayService().refreshTrayManager();
        _stopDurationTimer();
        break;
      case VpnStatus.connecting:
        if (_stopRequestedWithoutRestart &&
            _nextStartId == DBConstants.defaultId) {
          await _updateRunningId(DBConstants.defaultId);
          eventBus.updateVpnLoading(false);
        } else {
          eventBus.updateVpnLoading(true);
          await _updateRunningId(_lastConfigId);
        }
        break;
      case VpnStatus.connected:
        if (_stopRequestedWithoutRestart &&
            _nextStartId == DBConstants.defaultId) {
          _vpnRunning = false;
          await _updateRunningId(DBConstants.defaultId);
          eventBus.updateVpnLoading(false);
          unawaited(AppHostApi().stopVpn());
          break;
        }
        _vpnRunning = true;
        _stopRequestedWithoutRestart = false;
        eventBus.updateVpnLoading(false);
        await _updateRunningId(_lastConfigId);
        await TrayService().refreshTrayManager();
        await _startDurationTimer();
        break;
    }
  }

  Future<void> _updateRunningId(int id) async {
    await PreferencesKey().saveRunningConfigId(id);
    final eventBus = AppEventBus.instance;
    eventBus.updateRunningId(id);
  }

  Future<void> _updateLastConfigId(int id) async {
    await PreferencesKey().saveLastConfigId(id);
    _lastConfigId = id;
  }

  Future<void> restartCurrentVpn() async {
    final eventBus = AppEventBus.instance;
    final configId = eventBus.state.runningId;
    if (configId == DBConstants.defaultId) return;
    _nextStartId = configId;
    _stopRequestedWithoutRestart = false;
    eventBus.updateVpnLoading(true);
    await AppHostApi().stopVpn();
  }

  Future<void> startDefaultVpn() async {
    final eventBus = AppEventBus.instance;
    if (eventBus.state.runningId != DBConstants.defaultId) {
      return;
    }

    final permission = await VpnService().checkPermission();
    if (!permission) {
      await NotificationService().pushNotification(
        appLocalizationsNoContext().homePageOpenSettings,
      );
      return;
    }

    final db = AppDatabase();
    if (_lastConfigId == DBConstants.defaultId) {
      await _startRandomVpn();
    } else {
      final config = await db.coreConfigDao.searchRow(_lastConfigId);
      if (config == null) {
        await _startRandomVpn();
      } else {
        await startVpn(config.id);
      }
    }
  }

  Future<void> _startRandomVpn() async {
    final db = AppDatabase();
    final config = await db.coreConfigDao.randomConfig();
    if (config == null) {
      await NotificationService().pushNotification(
        appLocalizationsNoContext().vpnNoConfig,
      );
    } else {
      await startVpn(config.id);
    }
  }

  Future<void> stopDefaultVpn() async {
    await stopVpn(suppressReconnect: true);
  }

  Future<void> forceStopVpnForSignOut() async {
    await stopVpn(suppressReconnect: true, clearRuntimeConfig: true);
    try {
      await AppHostApi().readVpnStatus();
    } catch (error, stack) {
      debugPrint('VPN status verification after sign-out stop failed: $error');
      debugPrint('$stack');
    }
  }

  Future<void> stopVpn({
    bool suppressReconnect = true,
    bool clearRuntimeConfig = false,
  }) async {
    final eventBus = AppEventBus.instance;
    _nextStartId = DBConstants.defaultId;
    _stopRequestedWithoutRestart = suppressReconnect;
    _vpnRunning = false;
    if (clearRuntimeConfig) {
      await _updateLastConfigId(DBConstants.defaultId);
    }
    await _updateRunningId(DBConstants.defaultId);
    eventBus.updateVpnLoading(false);
    try {
      await AppHostApi().stopVpn();
    } catch (error, stack) {
      debugPrint('VPN stop failed: $error');
      debugPrint('$stack');
    } finally {
      await _updateRunningId(DBConstants.defaultId);
      eventBus.updateVpnLoading(false);
      _stopDurationTimer();
    }
  }

  Future<void> startVpn(int configId) async {
    if (configId == DBConstants.defaultId) {
      await stopDefaultVpn();
      return;
    }

    final eventBus = AppEventBus.instance;
    if (configId != eventBus.state.runningId) {
      _nextStartId = configId;
      _stopRequestedWithoutRestart = false;
    } else {
      await stopDefaultVpn();
      return;
    }
    if (!_vpnRunning) {
      await _updateRunningId(DBConstants.defaultId);
      await _tryStartVpn();
      return;
    }
    await AppHostApi().stopVpn();
  }

  Future<bool> checkPermission() async {
    if (AppPlatform.isAndroid) {
      final granted = await AppHostApi().checkVpnPermission();
      return granted;
    }
    return true;
  }

  Future<void> _tryStartVpn() async {
    final eventBus = AppEventBus.instance;
    if (_stopRequestedWithoutRestart && _nextStartId == DBConstants.defaultId) {
      await _updateRunningId(DBConstants.defaultId);
      eventBus.updateVpnLoading(false);
      return;
    }
    if (_nextStartId != DBConstants.defaultId) {
      final rowId = _nextStartId;

      _nextStartId = DBConstants.defaultId;
      eventBus.updateVpnLoading(true);

      final db = AppDatabase();
      final outbound = await db.coreConfigDao.searchRow(rowId);
      if (outbound != null) {
        try {
          await _realStartXray(outbound);
        } catch (error, stack) {
          debugPrint('VPN start failed: $error');
          debugPrint('$stack');
          await _cleanupFailedStart();
          Error.throwWithStackTrace(error, stack);
        }
      } else {
        await _updateRunningId(DBConstants.defaultId);
        eventBus.updateVpnLoading(false);
        ToastService().showToast(
          appLocalizationsNoContext().vpnSelectOneConfig,
        );
      }
    } else {
      await _updateRunningId(DBConstants.defaultId);
      eventBus.updateVpnLoading(false);
    }
  }

  Future<void> _cleanupFailedStart() async {
    _nextStartId = DBConstants.defaultId;
    _stopRequestedWithoutRestart = true;
    _vpnRunning = false;
    await _updateRunningId(DBConstants.defaultId);
    final eventBus = AppEventBus.instance;
    eventBus.updateVpnLoading(false);
    try {
      await AppHostApi().stopVpn();
    } catch (error, stack) {
      debugPrint('VPN cleanup after failed start failed: $error');
      debugPrint('$stack');
    }
    _stopDurationTimer();
  }

  Future<void> _realStartXray(CoreConfigData config) async {
    await _updateLastConfigId(config.id);
    await _updateRunningId(config.id);
    await PreferencesKey().saveVpnStartTimestamp();

    final runDir = VpnConstants.runDir;
    await FileTool.checkDir(runDir);

    final ports = await XrayPorts.getPorts();
    if (ports == null) {
      throw StateError('Could not allocate VPN ports.');
    }

    final db = AppDatabase();
    final outbound = await db.coreConfigDao.searchRow(config.id);
    if (outbound == null) {
      throw StateError('Prepared VPN config was not found.');
    }

    final coreConfigType = CoreConfigType.fromString(config.type);
    if (coreConfigType == null) {
      throw StateError('Prepared VPN config type is invalid.');
    }
    final tunSettingState = TunSettingState();
    await tunSettingState.readFromPreferences();
    await _applyConnectionProtectionPreference(tunSettingState);
    // Both configuration writers consult it (the Russian direct rule).
    ColituRuBypass.privacyMode = await PreferencesKey().readColituPrivacyMode();
    var configPath = "";
    switch (coreConfigType) {
      case CoreConfigType.outbound:
        configPath = await _writeXrayUIConfig(
          config,
          tunSettingState,
          ports,
          runDir,
        );
        break;
      case CoreConfigType.raw:
        configPath = await _writeXrayRawConfig(
          coreConfigType,
          config,
          tunSettingState,
          ports,
          runDir,
        );
        break;
      default:
        throw StateError('Prepared VPN config type is unsupported.');
    }

    await _clearXrayLog();

    final coreBase64Text = await _makeRunXrayRequest(configPath);
    if (coreBase64Text == null) {
      throw StateError('Could not prepare VPN start request.');
    }

    await _makeVpnRequestAndStart(
      coreBase64Text,
      runDir,
      ports,
      tunSettingState,
    );
  }

  Future<void> _applyConnectionProtectionPreference(
    TunSettingState tunSettingState,
  ) async {
    final enabled = await PreferencesKey().readColituKillSwitchEnabled();
    tunSettingState.onDemandEnabled = enabled;
    tunSettingState.disconnectOnSleep = false;
    tunSettingState.onDemandRules.clear();
    // Strict kill switch and split tunneling are written into the tunnel
    // profile on every start, so existing installs pick them up too.
    tunSettingState.includeAllNetworks =
        AppPlatform.isIOS && await PreferencesKey().readColituStrictKillSwitch();
    final split = SplitTunnelSettings.decode(
      await PreferencesKey().readColituSplitTunnel(),
    );
    ColituSplitTunnel.current = split;
    tunSettingState.excludedRoutes = ColituSplitTunnel.excludedRoutes(
      split,
      keepInside: [tunSettingState.tunDnsIPv4, tunSettingState.tunDnsIPv6],
    );
  }

  /// Starts fresh logs for a new session. The stability and core error logs
  /// of earlier sessions move to a bounded history file first: a user who
  /// reconnects because the tunnel felt broken would otherwise erase exactly
  /// the record of what went wrong.
  Future<void> _clearXrayLog() async {
    await Future.wait([
      File(XrayStateConstants.accessLogPath).writeAsString(""),
      appendToLogHistory(XrayStateConstants.errorLogPath, errorLogHistoryPath),
      appendToLogHistory(stabilityLogPath, stabilityLogHistoryPath),
    ]);
  }

  static String get stabilityLogPath => p.join(VpnConstants.runDir, 'stability_log.jsonl');
  static String get stabilityLogHistoryPath => p.join(VpnConstants.runDir, 'stability_log.prev.jsonl');
  static String get errorLogHistoryPath => p.join(VpnConstants.runDir, 'error.prev.log');

  /// Appends [path] to [historyPath], keeps the newest [maxBytes] of the
  /// history (cut at a line start) and empties [path].
  @visibleForTesting
  static Future<void> appendToLogHistory(
    String path,
    String historyPath, {
    int maxBytes = 256 << 10,
  }) async {
    final file = File(path);
    try {
      if (await file.exists() && await file.length() > 0) {
        final history = File(historyPath);
        final previous = await history.exists() ? await history.readAsBytes() : const <int>[];
        final current = await file.readAsBytes();
        var joined = [...previous, ...current];
        if (joined.length > maxBytes) {
          var start = joined.length - maxBytes;
          final newline = joined.indexOf(0x0A, start);
          start = newline >= 0 ? newline + 1 : start;
          joined = joined.sublist(start);
        }
        await history.writeAsBytes(joined, flush: true);
      }
      await file.writeAsString("");
    } catch (e) {
      ygLogger("log history: $e");
      try {
        await file.writeAsString("");
      } catch (_) {}
    }
  }

  Future<String> _writeXrayUIConfig(
    CoreConfigData config,
    TunSettingState tunSettingState,
    XrayPorts port,
    String runDir,
  ) async {
    final settingState = await XraySettingStateReader.loadFromDb();

    final outboundState = OutboundState();
    outboundState.readFromDbData(config);
    settingState.outbounds.outbounds.add(outboundState);

    await settingState.fixSetting(tunSettingState, port);
    _hardenDnsLeakProtection(settingState);
    if (await PreferencesKey().readColituAdBlock()) {
      ColituAdBlock.applyTo(settingState);
    }
    final xrayJson = settingState.xrayJson;
    final configPath = await xrayJson.writeConfig(runDir);
    return configPath;
  }

  void _hardenDnsLeakProtection(XraySettingState settingState) {
    settingState.routing.dnsQueryRule.outboundTag =
        RoutingOutboundTag.proxy.name;
    settingState.routing.dnsDoTRule.outboundTag = RoutingOutboundTag.proxy.name;
    settingState.outbounds.dns.dialerProxy = RoutingOutboundTag.proxy.name;
    for (final rule in settingState.routing.customRules) {
      if (rule.ruleTag == RoutingRuleTag.localDnsDirect) {
        rule.outboundTag = RoutingOutboundTag.proxy.name;
      }
    }
  }

  Future<String> _writeXrayRawConfig(
    CoreConfigType coreConfigType,
    CoreConfigData config,
    TunSettingState tunSettingState,
    XrayPorts port,
    String runDir,
  ) async {
    final bytes = base64Decode(config.data!);
    final rawText = utf8.decode(bytes);
    final jsonMap = JsonTool.decoder.convert(rawText);
    await XrayRawFix.fixConfig(jsonMap, tunSettingState, port);
    final configText = JsonTool.encoderForFile.convert(jsonMap);
    final configPath = XrayStateConstants.configFilePath;
    final file = File(configPath);
    await file.writeAsString(configText);
    return configPath;
  }

  Future<void> _makeVpnRequestAndStart(
    String coreBase64Text,
    String runDir,
    XrayPorts port,
    TunSettingState tunSettingState,
  ) async {
    final tunPriority = int.tryParse(tunSettingState.tunPriority);
    if (tunPriority == null) {
      return;
    }

    final request = StartVpnRequest(
      tunSettingState.tunJson,
      port.pingPort,
      coreBase64Text,
    );
    await request.writeToStartFile();

    await AppHostApi().startVpn();
  }

  Future<String?> _makeRunXrayRequest(String configPath) async {
    final xrayParam = RunXrayRequest(VpnConstants.datDir, configPath).toJson();

    final coreBase64Text = JsonTool.encodeJsonToBase64(xrayParam);
    return coreBase64Text;
  }

  Future<void> _connectivityTest() async {
    final request = await StartVpnRequestReader.readFromStartFile();
    if (request.pingPort == null) {
      return;
    }
    // delay three seconds
    await Future.delayed(Duration(seconds: 3));

    final pingState = PingState();
    await pingState.readFromPreferences();
    final location = await NetClient().connectivityTest(
      request.pingPort!,
      pingState.realUrl,
    );
    final eventBus = AppEventBus.instance;
    eventBus.updateLocation(location);
  }

  Timer? _timer;
  var _startTime = DateTime.now();

  Future<void> _startDurationTimer() async {
    _stopDurationTimer();
    _startTime = await PreferencesKey().readVpnStartTimestamp();
    _timer = Timer.periodic(Duration(seconds: 1), (_) => _updateDuration());
    await _connectivityTest();
  }

  void _stopDurationTimer() {
    _timer?.cancel();
    _timer = null;
    final eventBus = AppEventBus.instance;
    eventBus.updateLocation(GeoLocationStandard.standard);
  }

  void _updateDuration() {
    final now = DateTime.now();
    final duration = now.difference(_startTime);
    final languageCode =
        AppEventBus.instance.state.languageCode.locale.languageCode;
    final locale =
        DurationLocale.fromLanguageCode(languageCode) ??
        EnglishDurationLocale();
    final text = duration.pretty(locale: locale);
    final eventBus = AppEventBus.instance;
    eventBus.updateLocationDuration(text);
  }
}
