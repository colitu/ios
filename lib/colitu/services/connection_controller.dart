import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/colitu/services/user_service.dart';
import 'package:colitu_vpn/colitu/services/support_service.dart';
import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/server_latency.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/core/network/client.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:colitu_vpn/core/pigeon/flutter_api.dart';
import 'package:colitu_vpn/core/pigeon/messages.g.dart' show VpnStatus;
import 'package:colitu_vpn/core/pigeon/host_api.dart';
import 'package:colitu_vpn/service/event_bus/service.dart';
import 'package:colitu_vpn/service/event_bus/state.dart';
import 'package:colitu_vpn/service/vpn/service.dart' as engine;

enum ColituVpnStatus { disconnected, connecting, connected, disconnecting }

/// What the connect flow is doing right now; the home screen shows it under
/// the button so a slow step never looks like a hang.
enum ColituConnectPhase { idle, preparing, probing, starting, verifying, switching }

/// Everything the shell needs about the account and the tunnel, in one
/// listenable: servers, selection, connection state, session timer, live
/// traffic and the connection preferences. The mobile counterpart of the
/// Windows `ColituVpnService`.
class ColituConnectionController extends ChangeNotifier
    with WidgetsBindingObserver {
  ColituConnectionController({
    ColituVPNService? vpnService,
    ColituVPNConfigAdapter? adapter,
    SecureTokenStore? tokenStore,
    UserService? userService,
  }) : _vpnService = vpnService ?? ColituVPNService(),
       _adapter = adapter ?? ColituVPNConfigAdapter(),
       _tokenStore = tokenStore ?? SecureTokenStore(),
       _userService = userService;

  final ColituVPNService _vpnService;
  final UserService? _userService;
  final ColituVPNConfigAdapter _adapter;
  final SecureTokenStore _tokenStore;

  static const _stallPenalty = Duration(minutes: 10);
  static const _disconnectTimeout = Duration(seconds: 7);
  static const _refreshInterval = Duration(seconds: 60);
  static const _configTimeout = Duration(seconds: 20);
  static const _prepareTimeout = Duration(seconds: 16);
  static const _engineStartTimeout = Duration(seconds: 25);
  static const _verifyWindow = Duration(seconds: 9);

  /// A transport attempt that is still not settled after this long is decided
  /// by the engine state alone, so the screen can never stay on "connecting".
  /// The clock restarts for every transport the connect tries.
  static const _connectDeadline = Duration(seconds: 75);

  Timer? _refreshTimer;
  Timer? _clockTimer;
  Timer? _supportTimer;
  var _supportChecked = false;
  Future<void>? _disconnectOperation;
  var _refreshing = false;
  var _autoConnectAttempted = false;
  var _userDisconnected = false;
  var _wasTunnelRunning = false;
  var _connectSerial = 0;
  var _disposed = false;
  DateTime? _connectStartedAt;
  final Map<String, DateTime> _stalledTransports = {};

  /// Servers the tunnel reported as the problem, skipped by the automatic
  /// pick until the penalty passes.
  final Map<String, DateTime> _problemServers = {};
  static const _problemPenalty = Duration(minutes: 30);
  _TrafficSample? _lastTraffic;

  // ── Observable state ──────────────────────────────────────────────────
  var loading = true;
  var offline = false;
  ColituVpnStatus status = ColituVpnStatus.disconnected;
  ColituConnectPhase phase = ColituConnectPhase.idle;
  String? error;
  String? notice;
  String? verifiedPublicIp;

  /// Why the tunnel last stopped while the app was in the background, shown
  /// on the home screen until dismissed.
  String? dropReport;

  /// The tunnel restarted its core twice and traffic still did not flow:
  /// the server (or its network) is the problem. Read from the tunnel's
  /// heartbeat; with a pinned location the home screen offers
  /// [suggestedServer] instead of switching by itself.
  var serverProblem = false;
  VPNServer? suggestedServer;
  int connectedSeconds = 0;
  List<VPNServer> servers = const [];

  /// Multihop (double VPN) routes; empty on an older panel. Never part of
  /// the automatic "best server" pick.
  List<VPNServer> multihopServers = const [];
  VPNServer? selectedServer;
  VPNServer? connectedServer;
  VPNStatus? panelStatus;

  /// The account's rotating-exit-IP preference; null until known (or when the
  /// panel is too old to have one).
  RotationPreference? rotation;

  /// Where the rotation of the connected node is, while it is on.
  RotationStatus? rotationStatus;
  String? _rotationNode;
  var _rotationPollAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _lastRotationPoll = DateTime.fromMillisecondsSinceEpoch(0);
  var _rotationPolling = false;
  var _rotationEpoch = 0;
  var _foreground = true;

  /// Node id the tunnel is on (the panel's answer, which may differ from the
  /// list entry the user picked).
  String? _connectedNodeId;

  /// Panel transport in use ("hysteria2", "vless-reality", …).
  String? transport;

  /// Probe latency of the transport in use, -1 when unknown.
  int transportLatencyMs = -1;

  /// True once traffic was confirmed to flow through the tunnel.
  var verified = false;

  /// Live speed in bytes per second and the session totals, from the
  /// tunnel's packet bridge counters.
  double uploadBps = 0;
  double downloadBps = 0;
  int sessionUpBytes = 0;
  int sessionDownBytes = 0;

  /// Unread live-support replies (nav badge).
  int supportUnread = 0;

  /// Set by the shell while the support tab is on screen.
  var supportOpen = false;

  /// "Best server": the panel picks the node when no location is pinned.
  var autoSelection = true;

  var alwaysOn = false;
  var autoConnect = true;
  var adBlock = false;

  /// Privacy mode: Russian addresses go through the tunnel too.
  var privacyMode = false;

  /// Strict kill switch (iOS includeAllNetworks); off by default.
  var strictKillSwitch = false;

  /// Split tunneling (sites and addresses inside or outside the VPN).
  SplitTunnelSettings splitTunnel = SplitTunnelSettings.off;
  Timer? _splitRestart;

  /// Set while the panel says this device is over the plan's device limit
  /// (`DEVICE_OVER_LIMIT`): the home tab shows the paused page and nothing
  /// connects, by hand, automatically or on demand.
  DevicePause? paused;
  DateTime? _pauseStoppedAt;
  var _pauseFromStatus = false;

  /// The trial-end banner was dismissed today.
  var trialBannerDismissed = false;

  /// Set when the one-time "Russian sites go outside the VPN" notice should
  /// be shown; the shell shows it and calls [takeRuDirectNotice].
  var ruDirectNoticePending = false;

  /// Country of the server the tunnel connected to (the panel's answer, or
  /// the server list's).
  String? _connectedCountry;

  /// Called when the stored session is gone (signed out elsewhere, device
  /// removed); the shell returns to sign-in.
  VoidCallback? onSessionEnded;

  ColituUser? get user => AppSession.instance.currentUser;

  bool get busy =>
      status == ColituVpnStatus.connecting ||
      status == ColituVpnStatus.disconnecting;

  bool get connected => status == ColituVpnStatus.connected;

  bool get planActive =>
      panelStatus?.subscriptionActive ?? (user?.hasActiveEntitlement == true);

  bool get planRequired => panelStatus != null && !panelStatus!.subscriptionActive;

  bool get blocked => panelStatus?.blocked == true;

  Iterable<VPNServer> get selectableServers =>
      servers.where((server) => server.isSelectable);

  VPNServer? get effectiveServer => autoSelection
      ? (selectedServer ?? _bestServer())
      : selectedServer;

  String get transportName => colituTransportName(transport);

  /// Russian addresses leave the live tunnel directly (the connected-screen
  /// chip and the one-time notice).
  bool get ruDirectActive =>
      connected &&
      ColituRuBypass.appliesTo(
        _connectedCountry ?? connectedServer?.countryCode,
        privacyMode,
      );

  /// The live tunnel splits traffic (the home screen chip).
  bool get splitTunnelActive => connected && splitTunnel.active;

  /// The trial ends within three days and the banner was not dismissed
  /// today; null otherwise.
  TrialTransition? get trialBanner {
    final trial = panelStatus?.trial;
    if (trial == null || trialBannerDismissed || trial.nextPlan == null) {
      return null;
    }
    final left = trial.endsAt.difference(ColituClock.now());
    if (left.isNegative || left > const Duration(days: 3)) return null;
    return trial;
  }

  /// Human name for the location shown in the status line.
  String serverLabel(VPNServer? server) {
    if (server == null) return ColituLoc.I['server.auto'];
    return _serverTitle(server);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    alwaysOn = await PreferencesKey().readColituKillSwitchEnabled();
    autoConnect = await PreferencesKey().readColituAutoConnect();
    adBlock = await PreferencesKey().readColituAdBlock();
    privacyMode = await PreferencesKey().readColituPrivacyMode();
    ColituRuBypass.privacyMode = privacyMode;
    strictKillSwitch = await PreferencesKey().readColituStrictKillSwitch();
    splitTunnel = SplitTunnelSettings.decode(
      await PreferencesKey().readColituSplitTunnel(),
    );
    ColituSplitTunnel.current = splitTunnel;
    trialBannerDismissed =
        await PreferencesKey().readColituTrialBannerDismissed() == _today();
    if (_disposed) return;
    _notify();
    await _checkDrops();
    await load(showLoading: true);
    // Signed out (the shell went away) while loading: no timers for a
    // controller nobody uses any more.
    if (_disposed) return;
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => unawaited(load(showLoading: false)),
    );
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_tick()),
    );
    unawaited(_maybeAutoConnect());
    unawaited(checkSupport());
    _supportTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(checkSupport()),
    );
  }

  /// Updates the unread badge; a new reply shows a notice unless support is open.
  Future<void> checkSupport() async {
    try {
      final unread = await ColituSupportService().unread();
      if (_supportChecked && unread > supportUnread && !supportOpen) {
        notice = ColituLoc.I['support.newReply'];
      }
      supportUnread = unread;
      _supportChecked = true;
      _notify();
    } catch (_) {
      // The badge is best-effort; support may be switched off in the panel.
    }
  }

  void setSupportUnread(int value) {
    supportUnread = value < 0 ? 0 : value;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _clockTimer?.cancel();
    _supportTimer?.cancel();
    _splitRestart?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkDrops());
      unawaited(load(showLoading: false));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── Account and server list ───────────────────────────────────────────

  /// Refreshes account, entitlement and the server list. Returns false when
  /// the session is gone and the caller must show the sign-in screen.
  Future<bool> load({required bool showLoading}) async {
    if (_refreshing) return true;
    if (!showLoading && busy) return true;
    _refreshing = true;
    if (showLoading) {
      loading = true;
      error = null;
      _notify();
    }
    try {
      final tokens = await _tokenStore.readTokens();
      if (tokens == null) {
        onSessionEnded?.call();
        return false;
      }
      final account = await AppSession.instance.refreshAccount().timeout(
        const Duration(seconds: 15),
      );
      if (account.authState == ColituAuthState.unauthenticated) {
        onSessionEnded?.call();
        return false;
      }
      offline = account.authState == ColituAuthState.error;

      final panel = await _readStatus();
      if (panel != null) {
        panelStatus = panel;
        await _enforcePanelStatus(panel);
      }
      final fresh = await _readServers();
      if (fresh.servers.isNotEmpty) {
        servers = fresh.servers;
        multihopServers = fresh.multihop;
        unawaited(measurePings());
      }
      await _restoreSelection();
      if (!offline) await _loadRotationQuietly();
      _notify();
      return true;
    } catch (e, stack) {
      debugPrint('Colitu refresh failed: $e');
      debugPrint('$stack');
      offline = e is APIException &&
          (e.code == APIErrorCode.networkUnavailable ||
              e.code == APIErrorCode.backendUnavailable);
      if (showLoading && !offline) error = colituErrorMessage(e);
      return true;
    } finally {
      _refreshing = false;
      loading = false;
      _notify();
    }
  }

  Future<VPNStatus?> _readStatus() async {
    try {
      final fresh = await _vpnService.status().timeout(
        const Duration(seconds: 15),
      );
      // The account answers again (a device was removed, the plan grew):
      // a pause that came from this check ends with it.
      if (paused != null && _pauseFromStatus) paused = null;
      return fresh;
    } on APIException catch (e) {
      if (e.code == APIErrorCode.deviceOverLimit) {
        await _enterPause(DevicePause.fromDetails(e.details), fromStatus: true);
      }
      debugPrint('VPN status refresh failed: $e');
      return null;
    } catch (e) {
      debugPrint('VPN status refresh failed: $e');
      return null;
    }
  }

  // ── Paused device ─────────────────────────────────────────────────────

  /// The plan allows fewer devices than are active and this one is paused.
  /// The tunnel is stopped with on-demand switched off and the runtime
  /// configuration removed, so iOS cannot start it again by itself.
  Future<void> _enterPause(DevicePause pause, {bool fromStatus = false}) async {
    final first = paused == null;
    paused = pause;
    _pauseFromStatus = fromStatus;
    if (first) {
      _connectSerial++;
      _pauseStoppedAt = DateTime.now();
      await _resetTunnelState(clearRuntimeConfig: true);
      status = ColituVpnStatus.disconnected;
      phase = ColituConnectPhase.idle;
      connectedServer = null;
      transport = null;
      error = null;
      notice = null;
    }
    _notify();
  }

  /// "Use this device instead": makes this device the active one, then
  /// reads the account again. Throws when the panel refuses.
  Future<void> activateThisDevice() async {
    final id = await _tokenStore.readDeviceId();
    if (id == null || id.isEmpty) {
      throw const APIException(APIErrorCode.unknown, 'Device id is missing');
    }
    await (_userService ?? UserService()).activateDevice(id);
    paused = null;
    _notify();
    await load(showLoading: false);
  }

  /// Pull to refresh on the paused page: the configuration answers whether
  /// this device may connect again (another device was removed, the plan
  /// changed).
  Future<void> recheckPause() async {
    try {
      await _vpnService.config().timeout(_configTimeout);
      paused = null;
      _notify();
    } on APIException catch (e) {
      if (e.code == APIErrorCode.deviceOverLimit) {
        await _enterPause(DevicePause.fromDetails(e.details));
      }
    } catch (e) {
      debugPrint('Pause recheck failed: $e');
    }
    await load(showLoading: false);
  }

  Future<ServerCatalog> _readServers() async {
    try {
      return await _vpnService.catalog().timeout(const Duration(seconds: 15));
    } on APIException catch (e) {
      if (e.code == APIErrorCode.deviceOverLimit) {
        await _enterPause(DevicePause.fromDetails(e.details), fromStatus: true);
      }
      debugPrint('VPN servers refresh failed: $e');
      return const ServerCatalog([]);
    } catch (e) {
      debugPrint('VPN servers refresh failed: $e');
      return const ServerCatalog([]);
    }
  }

  Future<void> _restoreSelection() async {
    final savedId = await PreferencesKey().readColituSelectedServerId();
    if (savedId == null || savedId.isEmpty) {
      autoSelection = true;
      selectedServer = null;
      return;
    }
    // A saved multihop route is matched by its id only: the country matching
    // below would take every route for a node of the same exit country.
    for (final route in multihopServers) {
      if (route.identityKeys.contains(savedId)) {
        autoSelection = false;
        selectedServer = route;
        return;
      }
    }
    final resolution = resolveVPNServerSelection(servers, savedId);
    final restored = resolution.server;
    if (restored != null) {
      autoSelection = false;
      selectedServer = restored;
      if (resolution.shouldPersistSelection) {
        await PreferencesKey().saveColituSelectedServerId(
          restored.selectionKey,
        );
      }
    } else if (resolution.shouldClearSavedSelection ||
        resolution.status == VPNServerSelectionResolutionStatus.notFound) {
      autoSelection = true;
      selectedServer = null;
      await PreferencesKey().clearColituSelectedServerId();
    }
  }

  VPNServer? _bestServer({bool skipProblems = true}) {
    VPNServer? first;
    for (final server in servers) {
      if (!server.isSelectable) continue;
      if (skipProblems && _hasProblem(server)) continue;
      first ??= server;
      if (server.isRecommended) return server;
    }
    // Every usable server is flagged: the flags say nothing then.
    if (first == null && skipProblems) return _bestServer(skipProblems: false);
    return first;
  }

  bool _hasProblem(VPNServer server) {
    final until = _problemServers[server.selectionKey];
    if (until == null) return false;
    if (until.isAfter(DateTime.now())) return true;
    _problemServers.remove(server.selectionKey);
    return false;
  }

  /// The panel refused the tunnel (plan ended, update required): stop it.
  Future<void> _enforcePanelStatus(VPNStatus panel) async {
    if (panel.vpnAccountReady) return;
    final bus = AppEventBus.instance;
    final tunnelActive =
        bus.state.runningId != DBConstants.defaultId ||
        bus.state.vpnLoading ||
        engine.VpnService().vpnRunning;
    if (!tunnelActive) return;
    await _resetTunnelState(clearRuntimeConfig: true);
    error = panel.blocked ? _blockedMessage(panel) : ColituLoc.I['err.noPlan'];
  }

  String _blockedMessage(VPNStatus panel) {
    final loc = ColituLoc.I;
    if (panel.updateRequired) return loc['err.updateRequired'];
    final reason = panel.maintenanceMessage;
    return reason == null || reason.isEmpty
        ? loc['err.maintenance']
        : loc.format('err.blocked', {'reason': reason});
  }

  // ── Selection ─────────────────────────────────────────────────────────

  Future<void> selectServer(VPNServer server) async {
    if (!server.isSelectable) return;
    final previous = effectiveServer;
    autoSelection = false;
    selectedServer = server;
    error = null;
    await PreferencesKey().saveColituSelectedServerId(server.selectionKey);
    _notify();
    if (connected || status == ColituVpnStatus.connecting) {
      await _switchTo(server, previous: previous);
    }
  }

  Future<void> selectAuto() async {
    final previous = effectiveServer;
    autoSelection = true;
    selectedServer = null;
    error = null;
    await PreferencesKey().clearColituSelectedServerId();
    _notify();
    final target = _bestServer();
    if (target != null &&
        (connected || status == ColituVpnStatus.connecting) &&
        previous?.selectionKey != target.selectionKey) {
      await _switchTo(target, previous: previous);
    }
  }

  Future<void> _switchTo(VPNServer server, {VPNServer? previous}) async {
    notice = ColituLoc.I.format('locations.switching', {
      'server': _serverTitle(server),
    });
    _notify();
    try {
      await connect(reconnect: true);
    } on ColituPlanRequiredException {
      _fail(ColituLoc.I['err.noPlan']);
      return;
    }
    if (connected) {
      notice = ColituLoc.I.format('locations.switched', {
        'server': _serverTitle(connectedServer ?? server),
      });
      _notify();
    }
  }

  // ── Connect / disconnect ──────────────────────────────────────────────

  Future<void> toggle() async {
    if (connected || status == ColituVpnStatus.connecting) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> connect({bool reconnect = false}) async {
    if (status == ColituVpnStatus.disconnecting || loading) return;
    if (paused != null) return;
    if (status == ColituVpnStatus.connecting && !reconnect) return;
    final panel = panelStatus;
    if (panel != null && !panel.vpnAccountReady) {
      if (panel.blocked) {
        _fail(_blockedMessage(panel));
        return;
      }
      throw const ColituPlanRequiredException();
    }
    final server = effectiveServer;
    if (server == null) {
      _fail(ColituLoc.I['err.noServers']);
      return;
    }
    final serial = ++_connectSerial;
    _userDisconnected = false;
    _connectStartedAt = DateTime.now();
    status = ColituVpnStatus.connecting;
    phase = ColituConnectPhase.preparing;
    error = null;
    verified = false;
    verifiedPublicIp = null;
    _resetTraffic();
    _notify();
    try {
      // Whether the exit rotates decides the transports: learn it before
      // connecting if it is quickly known.
      if (rotation == null && !server.isMultihop) {
        await _loadRotationQuietly(timeout: const Duration(seconds: 3));
        if (serial != _connectSerial) return;
      }
      var config = server.isMultihop
          ? await _vpnService.routeConfig(server.id).timeout(_configTimeout)
          : await _vpnService
                .config(serverId: server.selectionKey)
                .timeout(_configTimeout);
      if (serial != _connectSerial) return;
      // A multihop route and a rotating exit run on VLESS only.
      if (server.isMultihop || config.isMultihop || rotation?.active == true) {
        final restricted = config.onlyVless();
        if (restricted == null) {
          _fail(
            ColituLoc.I[server.isMultihop
                ? 'multihop.needsVless'
                : 'rotation.needsVless'],
          );
          return;
        }
        config = restricted;
      }
      _connectedNodeId = config.isMultihop || server.isMultihop
          ? null
          : (config.serverId.isNotEmpty ? config.serverId : server.id);

      // Transports that stalled on this network a little earlier are tried
      // last; every transport the server offers is tried once before the
      // connect gives up, including one whose probe did not answer.
      final excluded = _activeStalls();
      final tried = <String>{};
      var engineStalled = false;
      final transports = config.outboundCandidates.length;
      final attempts = transports == 0 ? 1 : transports;
      String? lastProtocol;
      for (var attempt = 0; attempt < attempts; attempt++) {
        _connectStartedAt = DateTime.now();
        phase = ColituConnectPhase.probing;
        _notify();
        final int configId;
        try {
          configId = await _adapter
              .prepareConnectionConfig(
                config,
                server: server,
                excludeProtocols: excluded,
                skipProtocols: tried,
              )
              .timeout(_prepareTimeout);
        } on APIException catch (e) {
          // Only transports this build cannot read are left untried.
          if (attempt == 0 || e.code != APIErrorCode.configMissing) rethrow;
          break;
        }
        if (serial != _connectSerial) return;
        lastProtocol = _adapter.lastChosenProtocol;
        if (lastProtocol != null) tried.add(lastProtocol);
        transport = lastProtocol;
        transportLatencyMs = _adapter.lastChosenLatencyMs;

        phase = ColituConnectPhase.starting;
        _notify();
        if (!await engine.VpnService().checkPermission()) {
          throw const APIException(
            APIErrorCode.vpnPermissionDenied,
            'VPN permission denied',
          );
        }
        await PreferencesKey().saveVpnStartTimestamp();
        // The previous tunnel (another server, or the transport tried just
        // before) must be gone before the new one starts.
        await _ensureTunnelDown();
        if (serial != _connectSerial) return;
        ColituRuBypass.serverCountry = config.serverCountry ?? server.countryCode;
        _connectedCountry = ColituRuBypass.serverCountry;
        await engine.VpnService().startVpn(configId).timeout(_engineStartTimeout);
        var started = await _waitForVpnState(configId);
        if (!started) {
          await Future.delayed(const Duration(milliseconds: 600));
          final state = AppEventBus.instance.state;
          started = state.runningId == configId && !state.vpnLoading;
        }
        if (serial != _connectSerial) return;
        // A tunnel the system did not bring up in time is skipped like a
        // stalled one: the next transport gets its turn instead of the whole
        // connect failing.
        engineStalled = !started;
        if (!started) debugPrint('VPN engine did not confirm $lastProtocol');

        // The tunnel is up. Prove that traffic flows before calling it
        // connected; the check hits our own API and answers in a second.
        var ok = false;
        if (started) {
          phase = ColituConnectPhase.verifying;
          _wasTunnelRunning = true;
          _notify();
          ok = await _verifyTraffic(serial);
          if (serial != _connectSerial) return;
        }
        if (ok) {
          connectedServer = server;
          _resetRotationStatus();
          connectedSeconds = 0;
          verified = true;
          status = ColituVpnStatus.connected;
          phase = ColituConnectPhase.idle;
          notice = null;
          _notify();
          unawaited(_fetchPublicIp(serial));
          unawaited(_checkRuDirectNotice());
          // Starting the tunnel records a previous unclean exit, if any.
          unawaited(_checkDrops());
          return;
        }
        // The tunnel is up but carries no traffic: this transport stalls on
        // this network. Try the next one before giving up.
        if (lastProtocol != null && started) {
          _stalledTransports[lastProtocol] = DateTime.now().add(_stallPenalty);
          excluded.add(lastProtocol);
          debugPrint('Transport $lastProtocol stalled; excluding it');
        }
        final untried = config.outboundCandidates
            .where((c) => !tried.contains(c.protocolType))
            .length;
        if (attempt + 1 < attempts && untried > 0) {
          phase = ColituConnectPhase.switching;
          notice = ColituLoc.I['home.switchingTransport'];
          _notify();
        }
        await _resetTunnelState();
        if (untried == 0 || lastProtocol == null) break;
      }
      final reason = await _vpnService.latestTunnelFailureReason();
      throw ColituVerifyException(
        reason ?? (engineStalled ? 'core_not_running' : null),
      );
    } on ColituPlanRequiredException {
      rethrow;
    } catch (e, stack) {
      if (serial != _connectSerial) return;
      debugPrint('Connection failed: $e');
      debugPrint('$stack');
      if (e is APIException && e.code == APIErrorCode.deviceOverLimit) {
        await _enterPause(DevicePause.fromDetails(e.details));
        return;
      }
      await _resetTunnelState();
      if (e is APIException && e.backendCode == 'MULTIHOP_ROUTE_NOT_FOUND') {
        // The route was removed or renamed: learn the current list.
        _fail(ColituLoc.I['multihop.gone']);
        unawaited(load(showLoading: false));
        return;
      }
      if (e is APIException &&
          (e.code == APIErrorCode.subscriptionInactive ||
              e.code == APIErrorCode.premiumRequired ||
              e.code == APIErrorCode.freeDailyLimitReached) &&
          e.backendCode != 'DEVICE_LIMIT_REACHED' &&
          e.backendCode != 'DEVICE_LIMIT_EXCEEDED') {
        status = ColituVpnStatus.disconnected;
        phase = ColituConnectPhase.idle;
        _notify();
        throw const ColituPlanRequiredException();
      }
      // Engine/state errors are reported with the extension's last failure
      // reason so the message can say why the tunnel didn't start.
      final Object reported = e is APIException || e is ColituVerifyException
          ? e
          : e is TimeoutException
          ? e
          : ColituVerifyException(await _vpnService.latestTunnelFailureReason());
      _fail(colituErrorMessage(reported));
    }
  }

  Set<String> _activeStalls() {
    final now = DateTime.now();
    _stalledTransports.removeWhere((_, until) => until.isBefore(now));
    return _stalledTransports.keys.toSet();
  }

  void _fail(String message) {
    status = ColituVpnStatus.disconnected;
    phase = ColituConnectPhase.idle;
    error = message;
    notice = null;
    transport = null;
    _notify();
  }

  /// Polls the Colitu API through the tunnel for up to [_verifyWindow].
  Future<bool> _verifyTraffic(int serial) async {
    final deadline = DateTime.now().add(_verifyWindow);
    // Give the routing table a moment after the tunnel reports up.
    await Future.delayed(const Duration(milliseconds: 350));
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      if (serial != _connectSerial) return false;
      if (await NetClient().reachability()) return true;
      attempt++;
      await Future.delayed(
        Duration(milliseconds: attempt == 1 ? 500 : 900),
      );
    }
    return false;
  }

  Future<void> _fetchPublicIp(int serial) async {
    final ip = await NetClient().publicIp().timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
    if (serial != _connectSerial || !connected) return;
    verifiedPublicIp = ip;
    _notify();
  }

  Future<void> disconnect() async {
    final active = _disconnectOperation;
    if (active != null) return active;
    final operation = _performDisconnect();
    _disconnectOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_disconnectOperation, operation)) {
        _disconnectOperation = null;
      }
    }
  }

  Future<void> _performDisconnect() async {
    _connectSerial++;
    _userDisconnected = true;
    status = ColituVpnStatus.disconnecting;
    phase = ColituConnectPhase.idle;
    error = null;
    notice = null;
    _notify();
    try {
      await engine.VpnService().stopDefaultVpn().timeout(_disconnectTimeout);
      await _waitForVpnState(
        DBConstants.defaultId,
        timeout: const Duration(milliseconds: 1200),
      );
    } catch (e) {
      debugPrint('Disconnect failed: $e');
    } finally {
      await _markDisconnected();
      status = ColituVpnStatus.disconnected;
      connectedServer = null;
      transport = null;
      _notify();
    }
  }

  /// Stops a running tunnel and waits until iOS reports it disconnected.
  ///
  /// Starting while the previous tunnel was up handed the new start to the
  /// engine's "restart after the stop callback", and that callback sometimes
  /// never came: the switch then sat for 20 seconds and failed with "close
  /// other VPN apps" (diagnostics of 2026-10-01: 65 s between the old
  /// tunnel's stop and the next start). Here the stop is explicit and the
  /// start only follows once the system says the old tunnel is gone.
  Future<void> _ensureTunnelDown() async {
    if (await _tunnelDown(const Duration(milliseconds: 700))) return;
    try {
      await engine.VpnService()
          .stopVpn(suppressReconnect: true)
          .timeout(_disconnectTimeout);
    } catch (e) {
      debugPrint('Stopping the previous tunnel failed: $e');
    }
    if (!await _tunnelDown(const Duration(seconds: 8))) {
      debugPrint('Previous tunnel still reported up; starting anyway');
    }
    await _markDisconnected();
  }

  /// True once the system reports the tunnel disconnected within [timeout].
  Future<bool> _tunnelDown(Duration timeout) async {
    final completer = Completer<bool>();
    final sub = AppFlutterApi().vpnStatusController.stream.listen((status) {
      if (status == VpnStatus.disconnected && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final poller = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(AppHostApi().readVpnStatus());
    });
    unawaited(AppHostApi().readVpnStatus());
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      poller.cancel();
      await sub.cancel();
    }
  }

  Future<void> _resetTunnelState({bool clearRuntimeConfig = false}) async {
    try {
      await engine.VpnService()
          .stopVpn(
            suppressReconnect: true,
            clearRuntimeConfig: clearRuntimeConfig,
          )
          .timeout(_disconnectTimeout);
    } catch (e) {
      debugPrint('VPN cleanup failed: $e');
    }
    if (clearRuntimeConfig) {
      await _tokenStore.clearLastGoodConfig();
      await _adapter.clearRuntimeConfig();
      await PreferencesKey().saveLastConfigId(DBConstants.defaultId);
    }
    await _markDisconnected();
  }

  Future<void> _markDisconnected() async {
    await PreferencesKey().saveRunningConfigId(DBConstants.defaultId);
    final bus = AppEventBus.instance;
    bus.updateVpnLoading(false);
    bus.updateRunningId(DBConstants.defaultId);
    _wasTunnelRunning = false;
    connectedSeconds = 0;
    verifiedPublicIp = null;
    verified = false;
    _resetTraffic();
  }

  Future<bool> _waitForVpnState(
    int runningId, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final bus = AppEventBus.instance;
    bool matches(AppEventBusState state) =>
        state.runningId == runningId && !state.vpnLoading;
    if (matches(bus.state)) return true;
    final completer = Completer<bool>();
    late final StreamSubscription<AppEventBusState> sub;
    sub = bus.stream.listen((state) {
      if (matches(state) && !completer.isCompleted) completer.complete(true);
    });
    final poller = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(AppHostApi().readVpnStatus());
    });
    try {
      return await Future.any<bool>([
        completer.future,
        Future.delayed(timeout, () => false),
      ]);
    } finally {
      poller.cancel();
      await sub.cancel();
    }
  }

  Future<void> _maybeAutoConnect() async {
    if (_autoConnectAttempted) return;
    _autoConnectAttempted = true;
    if (!autoConnect) return;
    await Future.delayed(const Duration(milliseconds: 400));
    if (_disposed ||
        paused != null ||
        panelStatus?.vpnAccountReady != true ||
        effectiveServer == null ||
        AppEventBus.instance.state.runningId != DBConstants.defaultId) {
      return;
    }
    try {
      await connect();
    } on ColituPlanRequiredException {
      // The home screen already shows the plan prompt.
    }
  }

  // ── Session clock, traffic and tunnel watch ───────────────────────────

  Future<void> _tick() async {
    if (_disposed) return;
    final state = AppEventBus.instance.state;
    final running =
        state.runningId != DBConstants.defaultId && engine.VpnService().vpnRunning;
    if (running && paused != null) {
      // Started by iOS (on demand) while paused: stop it again, at most
      // every ten seconds; the stop also switches on-demand off.
      final last = _pauseStoppedAt;
      if (last == null ||
          DateTime.now().difference(last) > const Duration(seconds: 10)) {
        _pauseStoppedAt = DateTime.now();
        unawaited(_resetTunnelState(clearRuntimeConfig: true));
      }
      return;
    }
    if (running) {
      if (!_wasTunnelRunning && status == ColituVpnStatus.disconnected) {
        // The tunnel was already up (app relaunch, on-demand reconnect).
        connectedServer ??= effectiveServer;
        // A restart for a changed setting rewrites the configuration with it.
        ColituRuBypass.serverCountry ??= connectedServer?.countryCode;
        status = ColituVpnStatus.connected;
        phase = ColituConnectPhase.idle;
        error = null;
        unawaited(_checkRuDirectNotice());
      }
      _wasTunnelRunning = true;
      final started = await PreferencesKey().readVpnStartTimestamp();
      final seconds = DateTime.now().difference(started).inSeconds;
      connectedSeconds = seconds.clamp(0, 1 << 31);
      await _sampleTraffic();
      _checkConnectDeadline(running: true);
      _pollRotationIfDue();
      _notify();
      return;
    }
    if (status == ColituVpnStatus.connecting) {
      _checkConnectDeadline(running: false);
    }
    if (_wasTunnelRunning && !busy) {
      _wasTunnelRunning = false;
      final unexpected = !_userDisconnected;
      connectedSeconds = 0;
      verifiedPublicIp = null;
      verified = false;
      connectedServer = null;
      transport = null;
      serverProblem = false;
      suggestedServer = null;
      _resetTraffic();
      status = ColituVpnStatus.disconnected;
      phase = ColituConnectPhase.idle;
      if (unexpected && error == null) {
        error = alwaysOn ? null : ColituLoc.I['err.reconnectFailed'];
      }
      _notify();
    }
  }

  /// Safety net: a connect attempt that outlives every timeout is settled
  /// from the engine state so the button never stays on "connecting".
  void _checkConnectDeadline({required bool running}) {
    final startedAt = _connectStartedAt;
    if (status != ColituVpnStatus.connecting || startedAt == null) return;
    if (DateTime.now().difference(startedAt) < _connectDeadline) return;
    _connectSerial++;
    _connectStartedAt = null;
    if (running) {
      connectedServer ??= effectiveServer;
      status = ColituVpnStatus.connected;
      phase = ColituConnectPhase.idle;
      notice = null;
      _wasTunnelRunning = true;
    } else {
      _fail(ColituLoc.I['err.engine']);
    }
  }

  void _resetTraffic() {
    _lastTraffic = null;
    uploadBps = 0;
    downloadBps = 0;
    sessionUpBytes = 0;
    sessionDownBytes = 0;
  }

  /// Reads the counters the packet tunnel writes once a second and turns
  /// them into rates. Missing or stale files simply leave the speed at zero.
  Future<void> _sampleTraffic() async {
    try {
      final file = File(p.join(VpnConstants.runDir, 'traffic.json'));
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return;
      unawaited(_updateServerProblem(json['serverProblem'] == true));
      final sample = _TrafficSample(
        up: (json['up'] as num?)?.toInt() ?? 0,
        down: (json['down'] as num?)?.toInt() ?? 0,
        ts: (json['ts'] as num?)?.toInt() ?? 0,
      );
      final previous = _lastTraffic;
      _lastTraffic = sample;
      sessionUpBytes = sample.up;
      sessionDownBytes = sample.down;
      if (previous == null || sample.ts <= previous.ts) return;
      final seconds = (sample.ts - previous.ts) / 1000;
      if (seconds <= 0 || seconds > 10) {
        uploadBps = 0;
        downloadBps = 0;
        return;
      }
      final up = (sample.up - previous.up).clamp(0, 1 << 40) / seconds;
      final down = (sample.down - previous.down).clamp(0, 1 << 40) / seconds;
      // Light smoothing so the numbers read calmly instead of flickering.
      uploadBps = uploadBps * 0.35 + up * 0.65;
      downloadBps = downloadBps * 0.35 + down * 0.65;
    } catch (e) {
      debugPrint('Traffic sample failed: $e');
    }
  }

  /// Rising edge of the tunnel's "server problem" flag: keep the automatic
  /// pick away from this server, move to the next best one when the
  /// location is automatic, otherwise suggest it on the home screen.
  Future<void> _updateServerProblem(bool flagged) async {
    if (flagged == serverProblem) return;
    serverProblem = flagged;
    if (!flagged) {
      suggestedServer = null;
      _notify();
      return;
    }
    final current = connectedServer ?? effectiveServer;
    if (current == null) return;
    _problemServers[current.selectionKey] = DateTime.now().add(_problemPenalty);
    final alternative = _bestServer();
    if (alternative == null || alternative.selectionKey == current.selectionKey) {
      return;
    }
    if (!autoSelection) {
      suggestedServer = alternative;
      _notify();
      return;
    }
    await _switchTo(alternative, previous: current);
    if (connected) {
      notice = ColituLoc.I.format('server.problemSwitched', {
        'server': _serverTitle(connectedServer ?? alternative),
      });
      _notify();
    }
  }

  /// The user accepted the suggested server: pin it and move over.
  Future<void> switchToSuggested() async {
    final target = suggestedServer;
    suggestedServer = null;
    _notify();
    if (target != null) await selectServer(target);
  }

  // ── Preferences ───────────────────────────────────────────────────────

  Future<void> setAlwaysOn(bool value) async {
    alwaysOn = value;
    await PreferencesKey().saveColituKillSwitchEnabled(value);
    _notify();
    if (connected) {
      // The on-demand rules live in the tunnel manager; restarting the
      // tunnel applies them.
      unawaited(engine.VpnService().restartCurrentVpn());
    }
  }

  Future<void> setAutoConnect(bool value) async {
    autoConnect = value;
    await PreferencesKey().saveColituAutoConnect(value);
    _notify();
  }

  /// Ad blocking changes the core's DNS servers; a live tunnel is restarted
  /// so the new setting applies.
  Future<void> setAdBlock(bool value) async {
    if (adBlock == value) return;
    adBlock = value;
    await PreferencesKey().saveColituAdBlock(value);
    _notify();
    if (connected) unawaited(engine.VpnService().restartCurrentVpn());
  }

  /// Privacy mode adds or removes the Russian direct rule; a live tunnel is
  /// restarted so the new setting applies.
  Future<void> setPrivacyMode(bool value) async {
    if (privacyMode == value) return;
    privacyMode = value;
    ColituRuBypass.privacyMode = value;
    await PreferencesKey().saveColituPrivacyMode(value);
    _notify();
    if (connected) unawaited(engine.VpnService().restartCurrentVpn());
  }

  /// Strict kill switch: written into the VPN profile on the next start; a
  /// live tunnel is restarted so it applies now.
  Future<void> setStrictKillSwitch(bool value) async {
    if (strictKillSwitch == value) return;
    strictKillSwitch = value;
    await PreferencesKey().saveColituStrictKillSwitch(value);
    _notify();
    if (connected) unawaited(engine.VpnService().restartCurrentVpn());
  }

  /// Saves the split-tunneling setting. A live tunnel is restarted (once,
  /// after a short pause, so adding several sites in a row restarts it once)
  /// when the change affects the configuration.
  Future<void> setSplitTunnel(SplitTunnelSettings value) async {
    if (splitTunnel == value) return;
    final before = splitTunnel;
    splitTunnel = value;
    ColituSplitTunnel.current = value;
    await PreferencesKey().saveColituSplitTunnel(value.encode());
    _notify();
    if (!before.active && !value.active) return;
    _splitRestart?.cancel();
    _splitRestart = Timer(const Duration(milliseconds: 1200), () {
      if (connected && !_disposed) {
        unawaited(engine.VpnService().restartCurrentVpn());
      }
    });
  }

  /// Hides the trial-end banner until tomorrow.
  Future<void> dismissTrialBanner() async {
    trialBannerDismissed = true;
    _notify();
    await PreferencesKey().saveColituTrialBannerDismissed(_today());
  }

  static String _today() {
    final now = ColituClock.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  /// Flags the one-time notice when the connection that just came up sends
  /// Russian addresses outside the tunnel. With privacy mode on or a server
  /// in Russia nothing is recorded, so the notice comes the first time the
  /// rule really applies.
  Future<void> _checkRuDirectNotice() async {
    if (!ruDirectActive || ruDirectNoticePending) return;
    if (await PreferencesKey().readColituRuDirectNoticeShown()) return;
    if (_disposed || !ruDirectActive) return;
    ruDirectNoticePending = true;
    _notify();
  }

  /// The shell shows the notice now: it is recorded as shown, whatever the
  /// user picks.
  bool takeRuDirectNotice() {
    if (!ruDirectNoticePending) return false;
    ruDirectNoticePending = false;
    unawaited(PreferencesKey().saveColituRuDirectNoticeShown(true));
    return true;
  }

  void clearError() {
    error = null;
    _notify();
  }

  void clearNotice() {
    notice = null;
    _notify();
  }

  void clearDropReport() {
    dropReport = null;
    _notify();
  }

  // ── Background drops ──────────────────────────────────────────────────

  /// Stops the user asked for (iOS Settings, Control Center, the app itself)
  /// and app updates are not drops.
  static const _intentionalStops = {
    'userInitiated',
    'appUpdate',
    'userLogout',
    'userSwitch',
    'none',
  };

  Future<void> _checkDrops() async {
    try {
      final drops = await _vpnService.readDrops();
      if (drops.isEmpty) return;
      final seen = await PreferencesKey().readColituLastDropTs();
      final newest = drops.map((d) => d.timestamp).reduce((a, b) => a > b ? a : b);
      if (newest <= seen) return;
      await PreferencesKey().saveColituLastDropTs(newest);
      final fresh = drops
          .where((d) => d.timestamp > seen && !_intentionalStops.contains(d.kind))
          .toList();
      if (fresh.isEmpty) return;
      dropReport = describeDrop(fresh.last);
      _notify();
    } catch (e) {
      debugPrint('Drop check failed: $e');
    }
  }

  /// Footprint from which a kill without a crash report is put down to the
  /// packet-tunnel memory cap (about 50 MB).
  static const memoryKillMegabytes = 40;

  /// Localized one-paragraph explanation of a recorded drop.
  static String describeDrop(ColituTunnelDrop drop) {
    final loc = ColituLoc.I;
    final local = drop.at.toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final title = loc.format('drop.title', {'time': time});
    final bytes = drop.peakBytes > 0 ? drop.peakBytes : drop.memoryBytes;
    final megabytes = (bytes / (1 << 20)).round();
    final core = drop.goBytes > 0
        ? ' ${loc.format('drop.core', {'mb': (drop.goBytes / (1 << 20)).round()})}'
        : '';
    final String cause = switch (drop.kind) {
      // The last heartbeat is up to a second old: only a footprint near the
      // extension's ~50 MB cap is evidence of a memory kill.
      'killed' when megabytes >= memoryKillMegabytes =>
        loc.format('drop.killed', {'mb': megabytes}) + core,
      'killed' when megabytes > 0 =>
        loc.format('drop.killedLowMem', {'mb': megabytes}) + core,
      'killed' => loc['drop.killedNoMem'],
      'crashed' => drop.detail.isNotEmpty
          ? loc.format('drop.crashed', {
              'detail': drop.detail.endsWith('.') ? drop.detail : '${drop.detail}.',
            })
          : loc['drop.crashedNoDetail'],
      'noNetworkAvailable' ||
      'unrecoverableNetworkChange' ||
      'connectionFailed' => loc['drop.network'],
      'superceded' => loc['drop.superseded'],
      'providerDisabled' ||
      'configurationDisabled' ||
      'configurationRemoved' => loc['drop.disabled'],
      'sleep' || 'idleTimeout' => loc['drop.sleep'],
      'providerFailed' ||
      'configurationFailed' ||
      'internalError' => loc['drop.failed'],
      _ => loc.format('drop.other', {'reason': drop.kind}),
    };
    final restored = drop.restartedByIos ? ' ${loc['drop.restored']}' : '';
    return '$title. $cause$restored';
  }

  // ── Rotating exit IP ──────────────────────────────────────────────────

  /// Reads the preference; an older panel has none and it stays unknown.
  Future<void> _loadRotationQuietly({Duration? timeout}) async {
    try {
      final pending = _vpnService.rotation();
      final preference = await (timeout == null ? pending : pending.timeout(timeout));
      if (_disposed) return;
      final changed =
          rotation?.intervalSeconds != preference.intervalSeconds;
      rotation = preference;
      if (changed) _resetRotationStatus();
      _notify();
    } catch (e) {
      debugPrint('Rotation preference not loaded: $e');
    }
  }

  /// Reads the preference again (the rotation page opens, pull to refresh).
  Future<void> refreshRotation() => _loadRotationQuietly();

  /// Saves the interval and countries. Throws [APIException] (400
  /// `INVALID_PREFERENCE` for a country set the panel cannot serve). A
  /// tunnel on a non-VLESS transport is restarted so it can rotate.
  Future<void> saveRotation(int intervalSeconds, List<String> countries) async {
    final saved = await _vpnService.saveRotation(intervalSeconds, countries);
    rotation = saved;
    _resetRotationStatus();
    _notify();
    if (saved.active &&
        connected &&
        connectedServer?.isMultihop != true &&
        !ColituRotation.isVless(transport)) {
      await connect(reconnect: true);
    }
  }

  /// The node whose rotation the home screen follows: the connected one,
  /// while rotation is on and the tunnel is not a multihop route.
  String? get _rotationNodeId {
    if (!connected || rotation?.active != true) return null;
    if (connectedServer?.isMultihop == true) return null;
    final id = _connectedNodeId ?? connectedServer?.id;
    return id == null || id.isEmpty ? null : id;
  }

  /// The home screen's "Exit: Berlin · changes in 4:07"; null unless the
  /// panel reports the rotation as running for the connected node.
  ({String exit, Duration? left})? get rotationLine {
    final status = rotationStatus;
    final exit = status?.currentExit;
    if (_rotationNodeId == null || status == null || !status.active || exit == null) {
      return null;
    }
    final country = exit.country;
    final label = country != null && exit.label.toUpperCase() != country
        ? '${exit.label} ($country)'
        : exit.label;
    final next = status.nextChangeAt;
    return (
      exit: label,
      left: next?.difference(ColituClock.now().toUtc()),
    );
  }

  /// Asks for the status at the announced change time, never more often than
  /// every 60 seconds and only while the app is on screen.
  void _pollRotationIfDue() {
    final node = _rotationNodeId;
    if (node == null) {
      if (rotationStatus != null || _rotationNode != null) {
        _rotationNode = null;
        _resetRotationStatus();
      }
      return;
    }
    if (_rotationNode != node) {
      // Another node: what the last one reported does not apply.
      _rotationNode = node;
      _resetRotationStatus();
    }
    if (!_foreground || _rotationPolling) return;
    final now = DateTime.now();
    if (now.isBefore(_rotationPollAt) ||
        now.difference(_lastRotationPoll) <
            const Duration(seconds: ColituRotation.minStatusPollSeconds)) {
      return;
    }
    unawaited(_pollRotation(node));
  }

  Future<void> _pollRotation(String node) async {
    _rotationPolling = true;
    _lastRotationPoll = DateTime.now();
    final epoch = _rotationEpoch;
    try {
      final status = await _vpnService
          .rotationStatus(node)
          .timeout(const Duration(seconds: 15));
      if (epoch != _rotationEpoch || _disposed) return;
      rotationStatus = status;
      final now = DateTime.now();
      // Inactive (the node is not in the rotation mesh, too few exits): look
      // again later.
      _rotationPollAt = now.add(
        status.active
            ? ColituRotation.nextPollDelay(status.nextChangeAt, now.toUtc())
            : const Duration(minutes: 5),
      );
      _notify();
    } catch (e) {
      if (epoch == _rotationEpoch) {
        _rotationPollAt = DateTime.now().add(
          const Duration(seconds: ColituRotation.minStatusPollSeconds),
        );
      }
      debugPrint('Rotation status failed: $e');
    } finally {
      _rotationPolling = false;
    }
  }

  /// The shown status is stale (new node, new preference): poll again as soon
  /// as allowed.
  void _resetRotationStatus() {
    rotationStatus = null;
    _rotationPollAt = DateTime.fromMillisecondsSinceEpoch(0);
    _rotationEpoch++;
  }

  // ── Sign out ──────────────────────────────────────────────────────────

  Future<void> signOut() async {
    _connectSerial++;
    _userDisconnected = true;
    await AppSession.instance.logout();
    await PreferencesKey().clearColituSelectedServerId();
    await _markDisconnected();
    status = ColituVpnStatus.disconnected;
    phase = ColituConnectPhase.idle;
    connectedServer = null;
    selectedServer = null;
    transport = null;
    autoSelection = true;
    servers = const [];
    multihopServers = const [];
    rotation = null;
    _resetRotationStatus();
    panelStatus = null;
    _notify();
  }

  String _serverTitle(VPNServer server) {
    final code = server.countryCode;
    final country = code.length == 2
        ? ColituLoc.I.countryName(code)
        : server.displayCountry;
    // A route is named by its two ends ("Helsinki → Frankfurt").
    if (server.isMultihop) return server.name;
    final city = server.city?.trim();
    if (city != null && city.isNotEmpty && city.toLowerCase() != country.toLowerCase()) {
      return '$country · $city';
    }
    return country.isEmpty ? server.displayTitle : country;
  }

  /// Localized title for a server row.
  String titleOf(VPNServer server) => _serverTitle(server);

  /// Last measured ping per server (selection key), kept between runs. The
  /// panel sends where to measure, not a number.
  Map<String, int> _pings = const {};
  var _pingsLoaded = false;
  Future<void>? _pingRun;

  /// Ping of [server]: measured here, else whatever the panel sent.
  int? pingOf(VPNServer server) => _pings[server.selectionKey] ?? server.ping;

  /// Re-measures the pings unless a tunnel is up or starting.
  Future<void> measurePings() async {
    if (!_pingsLoaded) {
      _pingsLoaded = true;
      try {
        final raw = await PreferencesKey().readColituServerPings();
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          _pings = {
            for (final entry in decoded.entries)
              if (entry.value is num) entry.key: (entry.value as num).toInt(),
          };
          _notify();
        }
      } catch (_) {}
    }
    if (status != ColituVpnStatus.disconnected || _pingRun != null) return;
    final list = [...servers, ...multihopServers];
    final run = () async {
      final measured = await ServerLatency.measureAll(list);
      if (measured.isEmpty || status != ColituVpnStatus.disconnected) return;
      _pings = {..._pings, ...measured};
      _notify();
      await PreferencesKey().saveColituServerPings(jsonEncode(_pings));
    }();
    _pingRun = run;
    try {
      await run;
    } catch (_) {
    } finally {
      _pingRun = null;
    }
  }
}

class _TrafficSample {
  const _TrafficSample({required this.up, required this.down, required this.ts});

  final int up;
  final int down;
  final int ts;
}
