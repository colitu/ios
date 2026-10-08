import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';

class VPNServer {
  final String id;
  final String? locationId;
  final String? remnawaveNodeUuid;
  final String name;
  final bool hasBackendName;
  final String? displayName;
  final String country;
  final String? city;
  final String? flagCode;
  final int? ping;
  final String status;
  final bool available;
  final bool locked;
  final String? requiredPlan;
  final bool isPremium;
  final bool isFree;
  final bool isRecommended;
  final int? load;
  final String? healthCheckUrl;
  final String? testUrl;
  final String? host;
  final int? port;

  /// Third-party services the panel verified from this node's address
  /// (chatgpt, gemini, claude, netflix, youtube_premium).
  final List<String> services;

  /// Use-case categories from the panel: streaming, gaming, privacy, speed,
  /// torrent, ai (the panel adds streaming/ai when the service checks pass).
  final List<String> categories;

  /// A multihop (double VPN) route: [id] is the route id, [entry] the first
  /// hop and [exit] the node the traffic leaves from. [country]/[city] are
  /// the exit's; [host]/[port] probe the entry only.
  final bool isMultihop;
  final String? routeSlug;
  final RouteEndpoint? entry;
  final RouteEndpoint? exit;

  /// Chip and label order: what users look for most comes first.
  static const categoryOrder = ['ai', 'streaming', 'gaming', 'speed', 'privacy', 'torrent'];

  /// Category membership; older panels only sent services, so those count too.
  bool inCategory(String category) => switch (category) {
    'all' => true,
    'streaming' => categories.contains('streaming') || opensStreaming,
    'ai' => categories.contains('ai') || opensAi,
    _ => categories.contains(category),
  };

  /// "AI" means the ones users ask for most: Gemini and ChatGPT both open.
  static const requiredAiServices = ['gemini', 'chatgpt'];
  static const streamingServices = ['netflix', 'youtube_premium'];

  /// Display names in the order they are shown on a server row.
  static const serviceNames = {
    // Not a streaming service: it only says YouTube plays without ads here.
    'youtube_adfree': 'Ad-free YouTube',
    'chatgpt': 'ChatGPT',
    'gemini': 'Gemini',
    'claude': 'Claude',
    'netflix': 'Netflix',
    'youtube_premium': 'YouTube Premium',
  };

  bool get opensAi => requiredAiServices.every(services.contains);
  bool get opensStreaming => services.any(streamingServices.contains);

  const VPNServer({
    required this.id,
    this.locationId,
    this.remnawaveNodeUuid,
    required this.name,
    this.hasBackendName = true,
    this.displayName,
    required this.country,
    this.city,
    this.flagCode,
    this.ping,
    required this.status,
    required this.available,
    required this.locked,
    this.requiredPlan,
    required this.isPremium,
    required this.isFree,
    required this.isRecommended,
    this.load,
    this.healthCheckUrl,
    this.testUrl,
    this.host,
    this.port,
    this.services = const [],
    this.categories = const [],
    this.isMultihop = false,
    this.routeSlug,
    this.entry,
    this.exit,
  });

  bool get isAvailable => available;

  String get selectionKey =>
      _firstNonEmpty([locationId, id, remnawaveNodeUuid]) ?? id;

  List<String> get identityKeys {
    return [
      if (locationId != null && locationId!.isNotEmpty) locationId!,
      if (id.isNotEmpty) id,
      if (remnawaveNodeUuid != null && remnawaveNodeUuid!.isNotEmpty)
        remnawaveNodeUuid!,
    ];
  }

  bool get isLockedPremium => locked && requiredPlan == 'premium';

  bool get isSelectable => available && !locked;

  String get countryCode {
    final code =
        (flagCode?.isNotEmpty == true ? flagCode : null) ??
        _countryCodeFromCountry(country);
    return code.toUpperCase();
  }

  String get displayCountry {
    final normalized = country.trim();
    final code = countryCode;
    final looksLikeServerName =
        normalized.contains('[') || normalized.contains(' - ');
    if (normalized.isNotEmpty &&
        normalized.length > 2 &&
        !looksLikeServerName) {
      return normalized;
    }
    return _countryNames[code] ?? normalized.toUpperCase();
  }

  String get displayTitle {
    final cityCountry = _cityCountryTitle();
    return _firstNonEmpty([
          displayName,
          if (hasBackendName && !_isSyntheticServerName(name)) name,
          cityCountry,
          displayCountry,
          countryCode,
        ]) ??
        'VPN Server';
  }

  String get flagEmoji {
    final code = countryCode;
    if (code.length != 2) {
      return '🌐';
    }
    final first = code.codeUnitAt(0);
    final second = code.codeUnitAt(1);
    if (first < 65 || first > 90 || second < 65 || second > 90) {
      return '🌐';
    }
    return String.fromCharCodes([first + 127397, second + 127397]);
  }

  String get displaySubtitle {
    final parts = [
      displayCountry,
      if (city != null && city!.trim().isNotEmpty) city!.trim(),
      countryCode,
    ].where((part) => part.isNotEmpty).toSet().toList();
    return parts.isEmpty
        ? (isPremium ? 'Pro location' : 'Free location')
        : parts.join(' · ');
  }

  factory VPNServer.fromJson(Map<String, dynamic> json) {
    final backendName = _nullableString(json['name'] ?? json['title']);
    final locationId = _nullableString(
      json['locationId'] ?? json['location_id'] ?? json['location'],
    );
    final remnawaveNodeUuid = _nullableString(
      json['remnawaveNodeUuid'] ??
          json['remnawave_node_uuid'] ??
          json['nodeUuid'] ??
          json['node_uuid'] ??
          json['uuid'],
    );
    final requiredPlan = _nullableString(
      json['requiredPlan'] ?? json['required_plan'] ?? json['planRequired'],
    )?.toLowerCase();
    final countryCode = _string(
      json['countryCode'] ??
          json['country_code'] ??
          json['flagCode'] ??
          json['flag_code'] ??
          json['code'],
    );
    final country = _string(
      json['countryName'] ??
          json['country_name'] ??
          json['country'] ??
          countryCode,
    );
    final available =
        json.containsKey('available') || json.containsKey('isAvailable')
        ? _bool(json['available'] ?? json['isAvailable'])
        : _availableFromStatus(json['status']);
    final locked = _bool(json['locked'] ?? json['isLocked']);
    final routeEntry = RouteEndpoint.tryParse(json['entry']);
    final routeExit = RouteEndpoint.tryParse(json['exit']);
    final multihop =
        json['multihop'] != false && routeEntry != null && routeExit != null;
    final premium =
        _bool(json['isPremium'] ?? json['premium']) ||
        requiredPlan == 'premium' ||
        (locked && requiredPlan == 'premium');
    return VPNServer(
      id: '${json['id'] ?? ''}',
      locationId: locationId,
      remnawaveNodeUuid: remnawaveNodeUuid,
      name: backendName ?? 'VPN Server',
      hasBackendName: backendName != null,
      displayName: _nullableString(json['displayName'] ?? json['display_name']),
      country: country,
      city: _nullableString(json['city'] ?? json['region']),
      flagCode: multihop && routeExit.country != null
          ? routeExit.country
          : _nullableString(
              json['flagCode'] ?? json['flag_code'] ?? countryCode,
            ),
      ping: (json['ping'] as num?)?.toInt(),
      status:
          '${json['status'] ?? (json['available'] == false ? 'OFFLINE' : 'AVAILABLE')}',
      available: available,
      locked: locked,
      requiredPlan: requiredPlan,
      isPremium: premium,
      isFree: _bool(json['free']) || !premium,
      isRecommended: _bool(json['isRecommended'] ?? json['recommended']),
      load: _loadPercent(json['load']),
      healthCheckUrl: _nullableString(
        json['healthCheckUrl'] ?? json['health_check_url'] ?? json['healthUrl'],
      ),
      testUrl: _nullableString(json['testUrl'] ?? json['test_url']),
      host: _nullableString(
        json['host'] ??
            json['hostname'] ??
            json['address'] ??
            json['latency_host'],
      ),
      port: _intOrNull(
        json['port'] ??
            json['testPort'] ??
            json['test_port'] ??
            json['latency_port'],
      ),
      services: json['services'] is List
          ? [for (final value in json['services'] as List) if (value is String) value]
          : const [],
      categories: json['categories'] is List
          ? [
              for (final value in (json['categories'] as List).whereType<String>().map((v) => v.toLowerCase()).toSet())
                value,
            ]
          : const [],
      isMultihop: multihop,
      routeSlug: multihop ? _nullableString(json['route_slug']) : null,
      entry: multihop ? routeEntry : null,
      exit: multihop ? routeExit : null,
    );
  }

  /// The `multihop` array of `GET /servers` (or `servers` of
  /// `GET /multihop/servers`): routes with an id and both ends. An older
  /// panel sends none.
  static List<VPNServer> parseMultihop(Object? list) {
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic> && '${item['id'] ?? ''}'.isNotEmpty)
          VPNServer.fromJson(item),
    ].where((server) => server.isMultihop).toList();
  }

  String? _cityCountryTitle() {
    final cityText = city?.trim();
    final countryText = displayCountry.trim();
    if (cityText != null && cityText.isNotEmpty && countryText.isNotEmpty) {
      return '$cityText · $countryText';
    }
    return null;
  }
}

enum VPNServerSelectionResolutionStatus {
  noSavedSelection,
  restored,
  migratedLegacyCountryCode,
  ambiguousLegacyCountryCode,
  notFound,
}

class VPNServerSelectionResolution {
  const VPNServerSelectionResolution({required this.status, this.server});

  final VPNServerSelectionResolutionStatus status;
  final VPNServer? server;

  bool get shouldPersistSelection =>
      status == VPNServerSelectionResolutionStatus.migratedLegacyCountryCode;

  bool get shouldClearSavedSelection =>
      status == VPNServerSelectionResolutionStatus.ambiguousLegacyCountryCode;

  bool get blocksFallbackAutoPick =>
      status == VPNServerSelectionResolutionStatus.ambiguousLegacyCountryCode;
}

VPNServerSelectionResolution resolveVPNServerSelection(
  List<VPNServer> servers,
  String? savedValue,
) {
  final saved = savedValue?.trim();
  if (saved == null || saved.isEmpty) {
    return const VPNServerSelectionResolution(
      status: VPNServerSelectionResolutionStatus.noSavedSelection,
    );
  }

  for (final server in servers) {
    if (server.identityKeys.contains(saved)) {
      return VPNServerSelectionResolution(
        status: VPNServerSelectionResolutionStatus.restored,
        server: server,
      );
    }
  }

  final legacyCountryMatches = servers
      .where(
        (server) => server.countryCode.toLowerCase() == saved.toLowerCase(),
      )
      .toList();
  if (legacyCountryMatches.length == 1) {
    return VPNServerSelectionResolution(
      status: VPNServerSelectionResolutionStatus.migratedLegacyCountryCode,
      server: legacyCountryMatches.single,
    );
  }
  if (legacyCountryMatches.length > 1) {
    return const VPNServerSelectionResolution(
      status: VPNServerSelectionResolutionStatus.ambiguousLegacyCountryCode,
    );
  }
  return const VPNServerSelectionResolution(
    status: VPNServerSelectionResolutionStatus.notFound,
  );
}

VPNServer? resolveVPNServerForLoad({
  required List<VPNServer> servers,
  required VPNServerSelectionResolution selectionResolution,
  VPNServer? currentSelection,
}) {
  final restored = selectionResolution.server;
  if (restored != null) return restored;
  if (selectionResolution.blocksFallbackAutoPick) return null;

  if (currentSelection != null &&
      servers.any(
        (item) =>
            item.identityKeys.any(currentSelection.identityKeys.contains) &&
            item.isSelectable,
      )) {
    return currentSelection;
  }

  VPNServer? firstSelectable;
  VPNServer? firstRecommended;
  for (final server in servers) {
    if (!server.isSelectable) continue;
    firstSelectable ??= server;
    if (server.isRecommended) {
      firstRecommended = server;
      break;
    }
  }
  return firstRecommended ?? firstSelectable;
}

class VPNConfig {
  final String id;
  final String serverId;
  /// ISO country of the server the panel picked (it may fall back to another).
  final String? serverCountry;
  final String protocolType;
  final Map<String, dynamic>? outboundConfig;
  final List<VPNOutboundCandidate> outboundCandidates;
  final String? subscriptionUrl;
  final String? rawConfig;
  final DateTime? expiresAt;

  /// The envelope's `server` is a multihop route: the ends of the route.
  final bool isMultihop;
  final RouteEndpoint? entry;
  final RouteEndpoint? exit;

  const VPNConfig({
    required this.id,
    required this.serverId,
    this.serverCountry,
    required this.protocolType,
    this.outboundConfig,
    this.outboundCandidates = const [],
    this.subscriptionUrl,
    this.rawConfig,
    this.expiresAt,
    this.isMultihop = false,
    this.entry,
    this.exit,
  });

  /// A multihop route and a rotating exit run on VLESS only: the other
  /// transports cannot be carried through the mesh. This config with just the
  /// VLESS candidates (itself when all are VLESS), or null when none is left.
  VPNConfig? onlyVless() {
    final vless = [
      for (final c in outboundCandidates)
        if (ColituRotation.isVless(c.protocolType)) c,
    ];
    if (vless.isEmpty) return null;
    if (vless.length == outboundCandidates.length) return this;
    return VPNConfig(
      id: id,
      serverId: serverId,
      serverCountry: serverCountry,
      protocolType: vless.first.protocolType,
      outboundConfig: vless.first.outboundConfig,
      outboundCandidates: vless,
      subscriptionUrl: subscriptionUrl,
      rawConfig: rawConfig,
      expiresAt: expiresAt,
      isMultihop: isMultihop,
      entry: entry,
      exit: exit,
    );
  }

  bool get hasConnectionPayload {
    return _hasText(rawConfig) ||
        _hasText(subscriptionUrl) ||
        outboundCandidates.isNotEmpty ||
        (outboundConfig != null && outboundConfig!.isNotEmpty);
  }

  factory VPNConfig.fromJson(Map<String, dynamic> json) {
    final profile = _map(json['profile']);
    if (profile != null) {
      final primary = VPNOutboundCandidate.fromProfile(profile);
      final candidates = <VPNOutboundCandidate>[primary];
      final seen = <String>{primary.protocolType};
      final rawCandidates = json['candidates'];
      if (rawCandidates is List) {
        for (final value in rawCandidates.whereType<Map<String, dynamic>>()) {
          final candidateProfile = _map(value['profile']);
          if (candidateProfile == null) continue;
          try {
            final candidate = VPNOutboundCandidate.fromProfile(
              candidateProfile,
            );
            if (seen.add(candidate.protocolType)) candidates.add(candidate);
          } on FormatException {
            // One malformed optional transport must not hide a working one.
          }
        }
      }
      return VPNConfig(
        id: '${json['revision'] ?? ''}',
        serverId: '${_map(json['server'])?['id'] ?? ''}',
        serverCountry: _nullableString(_map(json['server'])?['country']),
        protocolType: primary.protocolType,
        outboundConfig: primary.outboundConfig,
        outboundCandidates: candidates,
        expiresAt: _date(json['expires_at']),
        isMultihop: _map(json['server'])?['multihop'] == true,
        entry: RouteEndpoint.tryParse(_map(json['server'])?['entry']),
        exit: RouteEndpoint.tryParse(_map(json['server'])?['exit']),
      );
    }
    final outbound =
        json['outboundConfig'] ?? json['outbound_config'] ?? json['outbound'];
    final server = _map(json['server']);
    return VPNConfig(
      id: '${json['id'] ?? json['uuid'] ?? json['configId'] ?? json['config_id'] ?? ''}',
      serverId:
          '${json['serverId'] ?? json['server_id'] ?? server?['id'] ?? ''}',
      protocolType:
          '${json['protocolType'] ?? json['protocol_type'] ?? json['protocol'] ?? json['type'] ?? json['configType'] ?? json['config_type'] ?? ''}',
      outboundConfig: outbound is Map<String, dynamic> ? outbound : null,
      outboundCandidates: outbound is Map<String, dynamic>
          ? [
              VPNOutboundCandidate(
                protocolType:
                    '${json['protocolType'] ?? json['protocol_type'] ?? json['protocol'] ?? ''}',
                outboundConfig: outbound,
              ),
            ]
          : const [],
      subscriptionUrl: _nullableString(
        json['subscriptionUrl'] ??
            json['subscription_url'] ??
            json['configUrl'] ??
            json['config_url'],
      ),
      rawConfig: _nullableString(
        json['rawConfig'] ??
            json['raw_config'] ??
            json['raw'] ??
            json['config'] ??
            json['configText'] ??
            json['config_text'] ??
            json['wireguardConfig'] ??
            json['wireguard_config'] ??
            json['openvpnConfig'] ??
            json['openvpn_config'],
      ),
      expiresAt: _date(json['expiresAt'] ?? json['expireAt']),
    );
  }
}

class VPNOutboundCandidate {
  const VPNOutboundCandidate({
    required this.protocolType,
    required this.outboundConfig,
  });

  final String protocolType;
  final Map<String, dynamic> outboundConfig;

  factory VPNOutboundCandidate.fromProfile(Map<String, dynamic> profile) {
    if (profile['format'] != 'xray-mobile-v1') {
      throw const FormatException('Unsupported mobile config format');
    }
    final payload = _map(profile['payload']);
    if (payload == null || payload['schema_version'] != 1) {
      throw const FormatException('Unsupported xray-mobile-v1 schema');
    }
    final protocol = '${payload['protocol'] ?? ''}';
    final endpoint = _map(payload['endpoint']);
    final credentials = _map(payload['credentials']);
    final transport = _map(payload['transport']);
    final security = _map(payload['security']);
    if (!const {
          'vless-reality',
          'vless-xhttp',
          'hysteria2',
          'trojan',
          'shadowsocks',
        }.contains(protocol) ||
        endpoint == null ||
        credentials == null ||
        transport == null ||
        security == null) {
      throw const FormatException('Incomplete mobile profile');
    }
    final host = '${endpoint['host'] ?? ''}';
    final port = endpoint['port'];
    if (host.isEmpty || port is! int || port < 1 || port > 65535) {
      throw const FormatException('Invalid mobile endpoint');
    }
    return VPNOutboundCandidate(
      protocolType: protocol,
      outboundConfig: _xrayMobileOutbound(
        protocol,
        host,
        port,
        credentials,
        transport,
        security,
      ),
    );
  }
}

class VPNStatus {
  final bool authenticated;
  final bool subscriptionActive;
  final String tier;
  final bool premiumAllowed;
  final bool vpnAccountReady;
  final ColituFreeQuota? freeQuota;
  final String? message;
  final bool updateRequired;
  final bool maintenanceActive;
  final String? maintenanceMessage;

  /// What happens when the running trial ends; null outside a trial or
  /// when the panel does not say.
  final TrialTransition? trial;

  const VPNStatus({
    required this.authenticated,
    required this.subscriptionActive,
    required this.tier,
    required this.premiumAllowed,
    required this.vpnAccountReady,
    this.freeQuota,
    this.message,
    this.updateRequired = false,
    this.maintenanceActive = false,
    this.maintenanceMessage,
    this.trial,
  });

  /// Connecting is refused for a reason other than the plan (app policy or
  /// maintenance); the plan itself may still be active.
  bool get blocked => updateRequired || maintenanceActive;

  factory VPNStatus.fromJson(Map<String, dynamic> json) {
    final source = _map(json['data']) ?? _map(json['status']) ?? json;
    final entitlement = _map(source['entitlement']);
    if (entitlement != null) {
      final status = '${entitlement['status'] ?? ''}'.toLowerCase();
      final active = status == 'active' || status == 'trialing';
      final policy = _map(source['app_policy']);
      final maintenance = _map(source['maintenance']);
      final blocked =
          policy?['update_required'] == true || maintenance?['active'] == true;
      return VPNStatus(
        authenticated: source['user'] is Map,
        subscriptionActive: active,
        tier: '${entitlement['plan'] ?? ''}',
        premiumAllowed: active,
        vpnAccountReady: active && !blocked,
        updateRequired: policy?['update_required'] == true,
        maintenanceActive: maintenance?['active'] == true,
        maintenanceMessage: maintenance?['message'] is String
            ? maintenance!['message'] as String
            : null,
        message: policy?['update_required'] == true
            ? 'Update Colitu before connecting.'
            : maintenance?['active'] == true
            ? '${maintenance?['message'] ?? 'Service maintenance is active.'}'
            : active
            ? null
            : 'An active entitlement is required.',
        trial: status == 'trialing' || status == 'trial_active'
            ? TrialTransition.fromBootstrap(entitlement, source)
            : null,
      );
    }
    return VPNStatus(
      authenticated: source['authenticated'] != false,
      subscriptionActive: _bool(
        source['subscriptionActive'] ?? source['subscription_active'],
      ),
      tier:
          '${source['tier'] ?? (source['subscriptionActive'] == true ? 'basic' : 'free')}',
      premiumAllowed: _bool(
        source['premiumAllowed'] ?? source['premium_allowed'],
      ),
      vpnAccountReady:
          source['vpnAccountReady'] != false &&
          source['vpn_account_ready'] != false,
      freeQuota:
          _map(
                source['freeQuota'] ?? source['free_quota'] ?? source['quota'],
              ) !=
              null
          ? ColituFreeQuota.fromJson(
              _map(
                source['freeQuota'] ?? source['free_quota'] ?? source['quota'],
              )!,
            )
          : null,
      message: source['message'] as String?,
    );
  }
}

/// The end of a trial as the panel describes it (bootstrap entitlement):
/// when it ends, the plan that follows and how many devices stay active.
/// Every number shown to the user comes from here.
class TrialTransition {
  const TrialTransition({
    required this.endsAt,
    this.nextPlan,
    this.nextDeviceLimit,
    this.nextMonthlyGb,
    this.deviceCount,
  });

  final DateTime endsAt;

  /// Id or name of the plan after the trial ("free").
  final String? nextPlan;
  final int? nextDeviceLimit;
  final int? nextMonthlyGb;

  /// Devices on the account now; null when the panel does not say.
  final int? deviceCount;

  bool get toFree => (nextPlan ?? '').trim().toLowerCase() == 'free';

  /// More devices than the next plan allows: the others get paused.
  bool get pausesDevices {
    final limit = nextDeviceLimit;
    final count = deviceCount;
    return limit != null && count != null && count > limit;
  }

  static TrialTransition? fromBootstrap(
    Map<String, dynamic> entitlement,
    Map<String, dynamic> source,
  ) {
    final endsAt = _date(
      entitlement['ends_at'] ??
          entitlement['trial_ends_at'] ??
          entitlement['expires_at'] ??
          source['trial_ends_at'],
    );
    if (endsAt == null) return null;
    final rawNext = entitlement['next_plan'] ?? source['next_plan'];
    final next = _map(rawNext);
    final nextPlan = next == null
        ? _nullableString(rawNext)
        : _nullableString(next['id'] ?? next['code'] ?? next['name']);
    int? first(List<Object?> values) {
      for (final value in values) {
        final number = _intOrNull(value);
        if (number != null && number >= 0) return number;
      }
      return null;
    }

    final gb = first([
      entitlement['next_monthly_gb'],
      entitlement['next_traffic_gb'],
      next?['monthly_gb'],
      next?['traffic_gb'],
    ]);
    final bytes = first([
      entitlement['next_traffic_limit_bytes'],
      entitlement['next_monthly_traffic_bytes'],
      next?['traffic_limit_bytes'],
      next?['monthly_traffic_bytes'],
    ]);
    final devices = source['devices'];
    // Contract: entitlement.devices = {active, suspended, registered, limit}.
    final counts = _map(entitlement['devices']);
    return TrialTransition(
      endsAt: endsAt,
      nextPlan: nextPlan,
      nextDeviceLimit: first([
        entitlement['next_device_limit'],
        source['next_device_limit'],
        next?['device_limit'],
      ]),
      nextMonthlyGb: gb ?? (bytes == null ? null : _gigabytes(bytes)),
      deviceCount: first([
        counts?['registered'],
        counts?['active'],
        entitlement['device_count'],
        entitlement['devices_count'],
        entitlement['active_device_count'],
        source['device_count'],
        source['devices_count'],
        if (devices is List) devices.length,
      ]),
    );
  }

  /// 10 GiB and 10 GB both read "10".
  static int _gigabytes(int bytes) =>
      bytes % (1 << 30) == 0 ? bytes >> 30 : (bytes / 1e9).round();
}

/// This device is paused: the plan allows fewer devices than are active
/// (`403 DEVICE_OVER_LIMIT` from the configuration or bootstrap).
class DevicePause {
  const DevicePause({required this.deviceLimit, this.activeDevices = const []});

  final int deviceLimit;
  final List<PausedPeer> activeDevices;

  factory DevicePause.fromDetails(Map<String, dynamic>? details) {
    final list = details?['active_devices'];
    return DevicePause(
      deviceLimit: _intOrNull(details?['device_limit']) ?? 1,
      activeDevices: [
        if (list is List)
          for (final item in list.whereType<Map<String, dynamic>>())
            PausedPeer(
              id: _string(item['id']),
              name: _string(item['name']),
              lastSeenAt: _date(item['last_seen_at']),
            ),
      ],
    );
  }
}

/// A device that is active while this one is paused.
class PausedPeer {
  const PausedPeer({required this.id, required this.name, this.lastSeenAt});

  final String id;
  final String name;
  final DateTime? lastSeenAt;
}

class VPNStatsSnapshot {
  final bool unlimited;
  final int totalUsedBytes;
  final int totalConnectedSeconds;
  final int serversUsed;
  final VPNStatsDay today;
  final List<VPNStatsDay> days;

  const VPNStatsSnapshot({
    required this.unlimited,
    required this.totalUsedBytes,
    required this.totalConnectedSeconds,
    required this.serversUsed,
    required this.today,
    required this.days,
  });

  factory VPNStatsSnapshot.fromJson(Map<String, dynamic> json) {
    final stats = _map(json['stats']) ?? json;
    final today = _map(stats['today']) ?? <String, dynamic>{};
    final days = stats['days'] is List ? stats['days'] as List : const [];
    return VPNStatsSnapshot(
      unlimited: _bool(json['unlimited']),
      totalUsedBytes: _intValue(
        stats['totalUsedBytes'] ?? stats['total_used_bytes'],
      ),
      totalConnectedSeconds: _intValue(
        stats['totalConnectedSeconds'] ?? stats['total_connected_seconds'],
      ),
      serversUsed: _intValue(stats['serversUsed'] ?? stats['servers_used']),
      today: VPNStatsDay.fromJson(today),
      days: days
          .whereType<Map<String, dynamic>>()
          .map(VPNStatsDay.fromJson)
          .toList(),
    );
  }
}

class VPNStatsDay {
  final String date;
  final int usedBytes;
  final int connectedSeconds;
  final int serversUsed;

  const VPNStatsDay({
    required this.date,
    required this.usedBytes,
    required this.connectedSeconds,
    required this.serversUsed,
  });

  factory VPNStatsDay.fromJson(Map<String, dynamic> json) {
    return VPNStatsDay(
      date: '${json['date'] ?? ''}',
      usedBytes: _intValue(json['usedBytes'] ?? json['used_bytes']),
      connectedSeconds: _intValue(
        json['connectedSeconds'] ?? json['connected_seconds'],
      ),
      serversUsed: _intValue(json['serversUsed'] ?? json['servers_used']),
    );
  }
}

DateTime? _date(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

String _string(Object? value) => '${value ?? ''}'.trim();

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}

Map<String, dynamic>? _map(Object? value) {
  return value is Map<String, dynamic> ? value : null;
}

bool _bool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    final normalized = value.toLowerCase().trim();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

int? _intOrNull(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

int _intValue(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

bool _isSyntheticServerName(String value) {
  return value.trim().toLowerCase() == 'vpn server';
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

bool _availableFromStatus(Object? value) {
  final normalized = '${value ?? 'AVAILABLE'}'.toUpperCase();
  return normalized == 'ACTIVE' ||
      normalized == 'AVAILABLE' ||
      normalized == 'ONLINE';
}

int? _loadPercent(Object? value) {
  if (value is num) return value.toInt();
  return switch ('$value'.toLowerCase()) {
    'low' => 25,
    'medium' => 55,
    'high' => 85,
    _ => null,
  };
}

Map<String, dynamic> _xrayMobileOutbound(
  String protocol,
  String host,
  int port,
  Map<String, dynamic> credentials,
  Map<String, dynamic> transport,
  Map<String, dynamic> security,
) {
  String requiredValue(Map<String, dynamic> value, String key) {
    final text = '${value[key] ?? ''}';
    if (text.isEmpty) throw FormatException('Missing $key');
    return text;
  }

  final stream = <String, dynamic>{
    'network': requiredValue(transport, 'type'),
    'security': requiredValue(security, 'type'),
  };
  if (security['type'] == 'reality') {
    stream['realitySettings'] = {
      'serverName': requiredValue(security, 'server_name'),
      'publicKey': requiredValue(security, 'public_key'),
      'shortId': requiredValue(security, 'short_id'),
      'fingerprint': '${security['fingerprint'] ?? 'chrome'}',
    };
  } else if (security['type'] == 'tls') {
    stream['tlsSettings'] = {
      'serverName': requiredValue(security, 'server_name'),
      // TCP TLS (Trojan) presents a Chrome fingerprint (uTLS): DPI in Russia
      // drops handshakes that look like Go's default client. QUIC (Hysteria2)
      // has its own handshake and takes no fingerprint.
      if (protocol != 'hysteria2') ...{
        'fingerprint': 'chrome',
        'alpn': ['h2', 'http/1.1'],
      },
    };
  }
  if (protocol == 'hysteria2') {
    if (transport['type'] != 'hysteria') {
      throw const FormatException('Invalid Hysteria2 transport');
    }
    stream['network'] = 'hysteria';
    stream['hysteriaSettings'] = {
      'version': 2,
      'auth': requiredValue(credentials, 'password'),
    };
    return {
      'tag': 'proxy',
      'protocol': 'hysteria',
      'settings': {'address': host, 'port': port},
      'streamSettings': stream,
    };
  }
  if (protocol == 'vless-xhttp') {
    if (transport['type'] != 'xhttp' || security['type'] != 'reality') {
      throw const FormatException('Invalid VLESS XHTTP transport');
    }
    final path = requiredValue(transport, 'path');
    if (!path.startsWith('/')) {
      throw const FormatException('Invalid VLESS XHTTP path');
    }
    stream['xhttpSettings'] = {
      'path': path,
      'mode': '${transport['mode'] ?? 'auto'}',
    };
    // XTLS Vision needs a raw TCP stream, which XHTTP does not carry.
    return {
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'address': host,
        'port': port,
        'id': requiredValue(credentials, 'uuid'),
        'encryption': 'none',
      },
      'streamSettings': stream,
    };
  }
  if (protocol == 'vless-reality') {
    return {
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'address': host,
        'port': port,
        'id': requiredValue(credentials, 'uuid'),
        'encryption': 'none',
        'flow': 'xtls-rprx-vision',
      },
      'streamSettings': stream,
    };
  }
  if (protocol == 'trojan') {
    return {
      'tag': 'proxy',
      'protocol': 'trojan',
      'settings': {
        'address': host,
        'port': port,
        'password': requiredValue(credentials, 'password'),
      },
      'streamSettings': stream,
    };
  }
  return {
    'tag': 'proxy',
    'protocol': 'shadowsocks',
    'settings': {
      'address': host,
      'port': port,
      'method': requiredValue(credentials, 'method'),
      'password': requiredValue(credentials, 'password'),
    },
  };
}

String _countryCodeFromCountry(String value) {
  final normalized = value.replaceAll('[OLD]', '').trim();
  if (normalized.length == 2) {
    return normalized.toUpperCase();
  }
  final leftSide = normalized.split(' - ').first.trim();
  if (leftSide.length == 2) {
    return leftSide.toUpperCase();
  }
  final leftLower = leftSide.toLowerCase();
  for (final entry in _countryNames.entries) {
    if (entry.value.toLowerCase() == leftLower) {
      return entry.key;
    }
  }
  final lower = normalized.toLowerCase();
  for (final entry in _countryNames.entries) {
    if (entry.value.toLowerCase() == lower) {
      return entry.key;
    }
  }
  return normalized.length >= 2 ? normalized.substring(0, 2).toUpperCase() : '';
}

const _countryNames = <String, String>{
  'AE': 'United Arab Emirates',
  'AR': 'Argentina',
  'AT': 'Austria',
  'AU': 'Australia',
  'BE': 'Belgium',
  'BG': 'Bulgaria',
  'BR': 'Brazil',
  'CA': 'Canada',
  'CH': 'Switzerland',
  'CN': 'China',
  'CZ': 'Czechia',
  'DE': 'Germany',
  'DK': 'Denmark',
  'ES': 'Spain',
  'FI': 'Finland',
  'FR': 'France',
  'GB': 'United Kingdom',
  'HK': 'Hong Kong',
  'HU': 'Hungary',
  'IE': 'Ireland',
  'IL': 'Israel',
  'IN': 'India',
  'IT': 'Italy',
  'JP': 'Japan',
  'KR': 'South Korea',
  'NL': 'Netherlands',
  'NO': 'Norway',
  'PL': 'Poland',
  'RO': 'Romania',
  'RU': 'Russia',
  'SE': 'Sweden',
  'SG': 'Singapore',
  'TR': 'Turkey',
  'UA': 'Ukraine',
  'UK': 'United Kingdom',
  'US': 'United States',
};
