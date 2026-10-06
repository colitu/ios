import 'dart:convert';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:path/path.dart' as p;

/// The server list answer: the nodes and the multihop routes.
class ServerCatalog {
  const ServerCatalog(this.servers, [this.multihop = const []]);

  final List<VPNServer> servers;
  final List<VPNServer> multihop;
}

class ColituVPNService {
  ColituVPNService({APIClient? client}) : _client = client ?? APIClient();

  final APIClient _client;

  Future<List<VPNServer>> servers() async => (await catalog()).servers;

  /// The server list with the multihop (double VPN) routes of the same answer
  /// (`multihop`; an older panel sends none).
  Future<ServerCatalog> catalog() {
    return _client.get(APIEndpoint.vpnServers, (json) {
      final list = _listFromJson(json, 'servers');
      final servers = list
          .whereType<Map<String, dynamic>>()
          .map(VPNServer.fromJson)
          .toList();
      if (servers.isEmpty) {
        throw const APIException(
          APIErrorCode.serverUnavailable,
          'Server is temporarily unavailable. Please try again later.',
        );
      }
      return ServerCatalog(
        servers,
        VPNServer.parseMultihop(json is Map ? json['multihop'] : null),
      );
    }, queryParameters: _freshQuery());
  }

  /// `GET /multihop/servers`: the routes only.
  Future<List<VPNServer>> multihopServers() {
    return _client.get(
      APIEndpoint.multihopServers,
      (json) => VPNServer.parseMultihop(json is Map ? json['servers'] : json),
      queryParameters: _freshQuery(),
    );
  }

  /// The route's own config: the envelope of `/config`, VLESS candidates only.
  /// 404 `MULTIHOP_ROUTE_NOT_FOUND` when the route was removed.
  Future<VPNConfig> routeConfig(String routeId) {
    return _client.get(
      APIEndpoint.multihopRouteConfig(routeId),
      _decodeConfig,
      queryParameters: _freshQuery(),
    );
  }

  Future<RotationPreference> rotation() {
    return _client.get(
      APIEndpoint.rotation,
      (json) => RotationPreference.fromJson(json is Map ? json['rotation'] : null),
      queryParameters: _freshQuery(),
    );
  }

  /// Saves the preference; 400 `INVALID_PREFERENCE` for a country set the
  /// panel cannot serve.
  Future<RotationPreference> saveRotation(
    int intervalSeconds,
    List<String> countries,
  ) {
    return _client.putRenewing(
      APIEndpoint.rotation,
      (json) => RotationPreference.fromJson(json is Map ? json['rotation'] : null),
      data: () => {
        'interval_seconds': intervalSeconds,
        'countries': ColituRotation.normalizeCountries(countries),
      },
    );
  }

  /// Where the rotation is for the node this device is connected to.
  Future<RotationStatus> rotationStatus(String nodeId) {
    return _client.get(
      APIEndpoint.rotationStatus,
      (json) => RotationStatus.fromJson(json is Map ? json['status'] : null),
      queryParameters: {'node_id': nodeId, ..._freshQuery()},
    );
  }

  Future<VPNServer> bestServer() async {
    final available = await servers();
    return available.firstWhere(
      (server) => server.isRecommended && server.isSelectable,
      orElse: () => available.firstWhere(
        (server) => server.isSelectable,
        orElse: () => available.first,
      ),
    );
  }

  Future<void> serverHealth(String serverId) {
    return Future<void>.value();
  }

  Future<VPNConfig> config({String? serverId}) async {
    if (serverId != null && serverId.isNotEmpty) {
      // Both calls are idempotent, so an expired access token is renewed
      // and the call repeated instead of failing the switch.
      await _client.putRenewing(
        APIEndpoint.userPreferences,
        (_) {},
        data: () => {'preferred_node_id': serverId},
      );
      await _client.postRenewing(
        APIEndpoint.configRefresh,
        (_) {},
        data: () => const {'current_revision': 0},
      );
    }
    return _client.get(
      APIEndpoint.vpnConfig,
      _decodeConfig,
      queryParameters: {..._freshQuery()},
    );
  }

  static VPNConfig _decodeConfig(Object? json) {
    final root = json is Map<String, dynamic> ? json : <String, dynamic>{};
    final map =
        _mapFromJson(root, 'config') ??
        _mapFromJson(root, 'vpnConfig') ??
        _mapFromJson(root, 'data') ??
        _mapFromJson(root, 'result') ??
        root;
    if (map.isEmpty) {
      throw const APIException(
        APIErrorCode.configMissing,
        'VPN configuration is missing or unsupported',
      );
    }
    final config = VPNConfig.fromJson(map);
    if (!config.hasConnectionPayload) {
      throw const APIException(
        APIErrorCode.configMissing,
        'VPN configuration is missing or unsupported',
      );
    }
    return config;
  }

  Future<VPNStatus> status() {
    return _client.get(
      APIEndpoint.vpnStatus,
      (json) => VPNStatus.fromJson(json as Map<String, dynamic>),
      queryParameters: _freshQuery(),
    );
  }

  Future<VPNStatsSnapshot> stats() {
    return _client.get(
      APIEndpoint.vpnStats,
      (json) => VPNStatsSnapshot.fromJson(json as Map<String, dynamic>),
      queryParameters: _freshQuery(),
    );
  }

  Future<void> recordStatsEvent({
    required String type,
    String? serverId,
    int connectedSeconds = 0,
    int usedBytes = 0,
  }) {
    return Future<void>.value();
  }

  Future<void> flushStabilityLogs() async {
    return;
  }

  Future<String?> latestTunnelFailureReason() async {
    final file = File(p.join(VpnConstants.runDir, 'stability_log.jsonl'));
    if (!await file.exists()) return null;
    try {
      final lines = await file.readAsLines();
      for (final line in lines.reversed.take(80)) {
        Object? value;
        try {
          value = jsonDecode(line);
        } catch (_) {
          continue;
        }
        if (value is! Map<String, dynamic>) continue;
        final event = '${value['event'] ?? ''}';
        if (event != 'core_start_failed' && event != 'core_crashed') {
          continue;
        }
        final reason = '${value['reason'] ?? ''}'.trim();
        return reason.isEmpty ? event : reason;
      }
    } catch (_) {
      // A packet-tunnel write can race with this best-effort diagnostic read.
    }
    return null;
  }

  /// Tunnel stops recorded by the packet-tunnel extension (run/drops.jsonl),
  /// oldest first. "killed" means iOS ended the extension without stopping it.
  Future<List<ColituTunnelDrop>> readDrops() async {
    final file = File(p.join(VpnConstants.runDir, 'drops.jsonl'));
    if (!await file.exists()) return const [];
    try {
      final drops = <ColituTunnelDrop>[];
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) continue;
        try {
          final value = jsonDecode(line);
          if (value is Map<String, dynamic>) drops.add(ColituTunnelDrop.fromJson(value));
        } catch (_) {
          // A torn line from a concurrent write; skip it.
        }
      }
      return drops;
    } catch (_) {
      return const [];
    }
  }

  Future<VPNConfig> subscriptionConfig() {
    return config();
  }
}

class ColituTunnelDrop {
  const ColituTunnelDrop({
    required this.at,
    required this.kind,
    this.memoryBytes = 0,
    this.peakBytes = 0,
    this.goBytes = 0,
    this.restartedByIos = false,
    this.detail = '',
  });

  final DateTime at;
  final String kind;
  final int memoryBytes;
  final int peakBytes;

  /// Part of the footprint held by the Go runtime (the VPN core).
  final int goBytes;
  final bool restartedByIos;

  /// First line of the crash report for a `crashed` drop.
  final String detail;

  int get timestamp => at.millisecondsSinceEpoch;

  factory ColituTunnelDrop.fromJson(Map<String, dynamic> json) {
    int number(Object? value) => value is num ? value.toInt() : 0;
    return ColituTunnelDrop(
      at: DateTime.fromMillisecondsSinceEpoch(number(json['ts'])),
      kind: '${json['kind'] ?? ''}',
      memoryBytes: number(json['mem']),
      peakBytes: number(json['peak']),
      goBytes: number(json['go']),
      restartedByIos: json['restartedBy'] == 'ios',
      detail: json['detail'] is String ? json['detail'] as String : '',
    );
  }
}

List<dynamic> _listFromJson(Object? json, String key) {
  if (json is List<dynamic>) {
    return json;
  }
  if (json is Map<String, dynamic>) {
    final data = json['data'];
    final result = json['result'];
    final value =
        json[key] ??
        json['items'] ??
        (result is Map<String, dynamic>
            ? result[key] ?? result['items']
            : result) ??
        (data is Map<String, dynamic> ? data[key] ?? data['items'] : data);
    if (value is List<dynamic>) {
      return value;
    }
  }
  return const [];
}

Map<String, dynamic>? _mapFromJson(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is Map<String, dynamic> ? value : null;
}

Map<String, dynamic> _freshQuery() {
  return {'_ts': DateTime.now().millisecondsSinceEpoch};
}
