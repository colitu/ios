import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/device_identity_service.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/outbound/enum.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_reader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rotating device identity replaces the account-bound key', () async {
    final store = _FakeTokenStore(null)..deviceKey = 'old-device-key';

    final key = await DeviceIdentityService(
      tokenStore: store,
    ).rotateDeviceKey();

    expect(key, isNot('old-device-key'));
    expect(key, hasLength(36));
    expect(store.deviceKey, key);
  });

  test('VPNServer decodes backend identity and access fields', () {
    final server = VPNServer.fromJson({
      'id': 'node-row-1',
      'locationId': 'loc-tr-1',
      'remnawaveNodeUuid': 'remna-uuid-1',
      'name': 'Turkey - Istanbul 1',
      'displayName': 'Istanbul Node 1',
      'countryCode': 'TR',
      'available': false,
      'locked': true,
      'requiredPlan': 'premium',
    });

    expect(server.id, 'node-row-1');
    expect(server.locationId, 'loc-tr-1');
    expect(server.remnawaveNodeUuid, 'remna-uuid-1');
    expect(server.displayName, 'Istanbul Node 1');
    expect(server.countryCode, 'TR');
    expect(server.available, isFalse);
    expect(server.locked, isTrue);
    expect(server.requiredPlan, 'premium');
    expect(server.isPremium, isTrue);
    expect(server.isLockedPremium, isTrue);
    expect(server.isSelectable, isFalse);
  });

  test('selectionKey prefers locationId over id over remnawaveNodeUuid', () {
    final withLocation = VPNServer.fromJson({
      'id': 'id-1',
      'locationId': 'loc-1',
      'remnawaveNodeUuid': 'uuid-1',
      'countryCode': 'US',
    });
    final withId = VPNServer.fromJson({
      'id': 'id-2',
      'remnawaveNodeUuid': 'uuid-2',
      'countryCode': 'US',
    });
    final withUuid = VPNServer.fromJson({
      'id': '',
      'remnawaveNodeUuid': 'uuid-3',
      'countryCode': 'US',
    });

    expect(withLocation.selectionKey, 'loc-1');
    expect(withId.selectionKey, 'id-2');
    expect(withUuid.selectionKey, 'uuid-3');
  });

  test('identityKeys contains locationId, id, and remnawaveNodeUuid', () {
    final server = VPNServer.fromJson({
      'id': 'id-1',
      'locationId': 'loc-1',
      'remnawaveNodeUuid': 'uuid-1',
      'countryCode': 'US',
    });

    expect(server.identityKeys, ['loc-1', 'id-1', 'uuid-1']);
  });

  test(
    'server service keeps locked premium and duplicate country rows',
    () async {
      final client = _clientFor((options) async {
        expect(options.path, APIEndpoint.vpnServers);
        return _jsonResponse({
          'servers': [
            {
              'id': 'row-1',
              'locationId': 'loc-us-1',
              'name': 'US Node 1',
              'countryCode': 'US',
              'available': true,
              'locked': false,
            },
            {
              'id': 'row-2',
              'locationId': 'loc-us-2',
              'name': 'US Premium Node 2',
              'countryCode': 'US',
              'available': false,
              'locked': true,
              'requiredPlan': 'premium',
            },
          ],
        });
      });

      final servers = await ColituVPNService(client: client).servers();

      expect(servers, hasLength(2));
      expect(servers.map((server) => server.countryCode), ['US', 'US']);
      expect(servers.last.isLockedPremium, isTrue);
    },
  );

  test('legacy countryCode migration only selects one exact match', () {
    final servers = [
      VPNServer.fromJson({
        'id': 'row-1',
        'locationId': 'loc-tr-1',
        'countryCode': 'TR',
      }),
      VPNServer.fromJson({
        'id': 'row-2',
        'locationId': 'loc-us-1',
        'countryCode': 'US',
      }),
    ];

    final result = resolveVPNServerSelection(servers, 'TR');

    expect(result.server?.selectionKey, 'loc-tr-1');
    expect(result.shouldPersistSelection, isTrue);
    expect(result.shouldClearSavedSelection, isFalse);
  });

  test('ambiguous legacy countryCode does not silently choose a server', () {
    final servers = [
      VPNServer.fromJson({
        'id': 'row-1',
        'locationId': 'loc-us-1',
        'countryCode': 'US',
      }),
      VPNServer.fromJson({
        'id': 'row-2',
        'locationId': 'loc-us-2',
        'countryCode': 'US',
      }),
    ];

    final result = resolveVPNServerSelection(servers, 'US');

    expect(result.server, isNull);
    expect(result.shouldPersistSelection, isFalse);
    expect(result.shouldClearSavedSelection, isTrue);
  });

  test('ambiguous legacy countryCode blocks home fallback auto-pick', () {
    final servers = [
      VPNServer.fromJson({
        'id': 'row-1',
        'locationId': 'loc-us-1',
        'countryCode': 'US',
        'available': true,
      }),
      VPNServer.fromJson({
        'id': 'row-2',
        'locationId': 'loc-us-2',
        'countryCode': 'US',
        'available': true,
        'isRecommended': true,
      }),
    ];

    final result = resolveVPNServerSelection(servers, 'US');
    final selected = resolveVPNServerForLoad(
      servers: servers,
      selectionResolution: result,
    );

    expect(result.shouldClearSavedSelection, isTrue);
    expect(selected, isNull);
  });

  test(
    'displayTitle ignores synthetic default name and falls back to city country',
    () {
      final server = VPNServer.fromJson({
        'id': 'row-1',
        'locationId': 'loc-us-1',
        'countryCode': 'US',
        'city': 'New York',
      });

      expect(server.name, 'VPN Server');
      expect(server.hasBackendName, isFalse);
      expect(server.displayTitle, 'New York · United States');
    },
  );

  test('displayTitle uses backend-provided name when present', () {
    final server = VPNServer.fromJson({
      'id': 'row-1',
      'locationId': 'loc-us-1',
      'countryCode': 'US',
      'city': 'New York',
      'name': 'US Node A',
    });

    expect(server.hasBackendName, isTrue);
    expect(server.displayTitle, 'US Node A');
  });

  test(
    'config request persists the selected backend node before fetch',
    () async {
      final paths = <String>[];
      String? selectedNodeId;
      final client = _clientFor((options) async {
        paths.add(options.path);
        if (options.path == APIEndpoint.userPreferences) {
          selectedNodeId =
              (options.data as Map<String, dynamic>)['preferred_node_id']
                  as String?;
          return _jsonResponse({'preferred_node_id': selectedNodeId});
        }
        if (options.path == APIEndpoint.configRefresh) {
          return _jsonResponse({'unchanged': true, 'revision': 1});
        }
        expect(options.path, APIEndpoint.vpnConfig);
        return _jsonResponse({
          'revision': 1,
          'expires_at': '2099-01-01T00:00:00Z',
          'offline_grace_until': '2099-01-02T00:00:00Z',
          'server': {'id': 'row-de-1'},
          'profile': {
            'format': 'xray-mobile-v1',
            'payload': {
              'schema_version': 1,
              'protocol': 'vless-reality',
              'endpoint': {'host': 'vpn.example.com', 'port': 443},
              'credentials': {'uuid': '00000000-0000-4000-8000-000000000001'},
              'transport': {'type': 'tcp'},
              'security': {
                'type': 'reality',
                'server_name': 'cdn.example.com',
                'public_key': 'public-key',
                'short_id': 'abcd',
                'fingerprint': 'chrome',
              },
            },
          },
        });
      });
      final server = VPNServer.fromJson({
        'id': 'row-de-1',
        'countryCode': 'DE',
      });

      await ColituVPNService(
        client: client,
      ).config(serverId: server.selectionKey);

      expect(selectedNodeId, 'row-de-1');
      expect(paths, [
        APIEndpoint.userPreferences,
        APIEndpoint.configRefresh,
        APIEndpoint.vpnConfig,
      ]);
    },
  );

  test('mobile Reality profile maps to the engine outbound schema', () {
    final config = VPNConfig.fromJson({
      'revision': 1,
      'expires_at': '2099-01-01T00:00:00Z',
      'server': {'id': 'row-ee-1'},
      'profile': {
        'format': 'xray-mobile-v1',
        'payload': {
          'schema_version': 1,
          'protocol': 'vless-reality',
          'endpoint': {'host': '203.0.113.10', 'port': 443},
          'credentials': {'uuid': '00000000-0000-4000-8000-000000000001'},
          'transport': {'type': 'tcp'},
          'security': {
            'type': 'reality',
            'server_name': 'www.cloudflare.com',
            'public_key': 'public-key',
            'short_id': 'abcd',
            'fingerprint': 'chrome',
          },
        },
      },
    });
    final state = OutboundState();

    expect(
      state.readFromOutbound(XrayOutbound.fromJson(config.outboundConfig!)),
      isTrue,
    );
    expect(state.address, '203.0.113.10');
    expect(state.port, '443');
    expect(state.vlessId, '00000000-0000-4000-8000-000000000001');
    expect(state.network, StreamSettingsNetwork.raw);
    expect(state.security, StreamSettingsSecurity.reality);
    expect(state.password, 'public-key');
    expect(state.shortId, 'abcd');
  });

  test('automatic config keeps valid protocol candidates', () {
    Map<String, dynamic> profile(
      String protocol,
      Map<String, dynamic> credentials,
      Map<String, dynamic> transport,
      Map<String, dynamic> security,
    ) => {
      'format': 'xray-mobile-v1',
      'payload': {
        'schema_version': 1,
        'protocol': protocol,
        'endpoint': {'host': 'vpn.example.com', 'port': 443},
        'credentials': credentials,
        'transport': transport,
        'security': security,
      },
    };
    final reality = profile(
      'vless-reality',
      {'uuid': '00000000-0000-4000-8000-000000000001'},
      {'type': 'tcp'},
      {
        'type': 'reality',
        'server_name': 'cdn.example.com',
        'public_key': 'public-key',
        'short_id': 'abcd',
      },
    );
    final hysteria = profile(
      'hysteria2',
      {'password': 'shared-secret'},
      {'type': 'hysteria'},
      {'type': 'tls', 'server_name': 'vpn.example.com'},
    );
    final config = VPNConfig.fromJson({
      'revision': 2,
      'expires_at': '2099-01-01T00:00:00Z',
      'server': {'id': 'row-ee-1'},
      'profile': reality,
      'candidates': [
        {'protocol': 'vless-reality', 'profile': reality},
        {'protocol': 'hysteria2', 'profile': hysteria},
      ],
    });

    expect(config.outboundCandidates.map((item) => item.protocolType), [
      'vless-reality',
      'hysteria2',
    ]);
    final state = OutboundState();
    expect(
      state.readFromOutbound(
        XrayOutbound.fromJson(config.outboundCandidates.last.outboundConfig),
      ),
      isTrue,
    );
    expect(state.protocol, XrayOutboundProtocol.hysteria);
    expect(state.hysteriaAuth, 'shared-secret');
    expect(state.network, StreamSettingsNetwork.hysteria);
    expect(state.security, StreamSettingsSecurity.tls);
  });

}

APIClient _clientFor(Future<ResponseBody> Function(RequestOptions) handler) {
  final dio = _testDio()..httpClientAdapter = _FakeAdapter(handler);
  final refreshDio = _testDio();
  return APIClient.testing(
    dio: dio,
    refreshDio: refreshDio,
    tokenStore: _FakeTokenStore(
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
    ),
  );
}

Dio _testDio() {
  return Dio(
    BaseOptions(
      baseUrl: 'https://api.test',
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
      validateStatus: (status) => status != null,
    ),
  );
}

ResponseBody _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class _FakeTokenStore implements SecureTokenStore {
  _FakeTokenStore(this.tokens);

  var _generation = 0;

  @override
  int get sessionGeneration => _generation;

  @override
  void beginSession() => _generation++;

  @override
  Future<bool> saveTokensIfCurrent(AuthTokens tokens, int generation) async {
    if (generation != _generation) return false;
    this.tokens = tokens;
    return true;
  }

  String? pendingEmail;

  @override
  Future<String?> readPendingVerificationEmail() async => pendingEmail;

  @override
  Future<void> savePendingVerificationEmail(String? email) async => pendingEmail = email;

  AuthTokens? tokens;
  String? deviceId = 'device-1';
  String? deviceKey = 'device-key-1';
  String? lastGoodConfig;
  String? configEtag;
  String? runtimePolicy;

  @override
  Future<void> clear() async {
    _generation++;
    tokens = null;
  }

  @override
  Future<void> clearLastGoodConfig() async {
    lastGoodConfig = null;
    configEtag = null;
  }

  @override
  Future<void> clearRuntimePolicy() async => runtimePolicy = null;

  @override
  Future<String?> readConfigEtag() async => configEtag;
  String? recoverySet;
  int? recoveryAttempt;

  @override
  Future<String?> readRecoverySet() async => recoverySet;

  @override
  Future<void> saveRecoverySet(String value) async => recoverySet = value;

  @override
  Future<void> clearRecoverySet() async => recoverySet = null;

  @override
  Future<int?> readRecoveryAttempt() async => recoveryAttempt;

  @override
  Future<void> saveRecoveryAttempt(int epochMs) async =>
      recoveryAttempt = epochMs;


  @override
  Future<String?> readLastGoodConfig() async => lastGoodConfig;

  @override
  Future<String?> readRuntimePolicy() async => runtimePolicy;

  @override
  Future<String?> readDeviceId() async => deviceId;

  @override
  Future<String?> readDeviceKey() async => deviceKey;

  @override
  Future<AuthTokens?> readTokens() async => tokens;

  @override
  Future<String?> readUserId() async => 'user-1';

  @override
  Future<void> saveDeviceId(String value) async {
    deviceId = value;
  }

  @override
  Future<void> saveDeviceKey(String value) async {
    deviceKey = value;
  }

  @override
  Future<void> saveConfigEtag(String value) async => configEtag = value;

  @override
  Future<void> saveLastGoodConfig(String value) async => lastGoodConfig = value;

  @override
  Future<void> saveRuntimePolicy(String value) async => runtimePolicy = value;

  @override
  Future<void> saveTokens(AuthTokens tokens, {String? userId}) async {
    this.tokens = tokens;
  }
}
