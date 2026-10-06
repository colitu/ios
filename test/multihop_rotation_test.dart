import 'dart:convert';
import 'dart:typed_data';

import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Panel contract 2026-10-06, sections 3 and 4: multihop routes (VLESS only)
/// and the rotating exit IP. Mirrors the Windows ColituMultihopTests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> route({
    String id = 'route-1',
    bool? multihop = true,
    bool entry = true,
    bool exit = true,
  }) => {
    'id': id,
    'route_slug': 'fi-de',
    'multihop': ?multihop,
    'name': 'Helsinki → Frankfurt',
    'country': 'DE',
    'city': 'Frankfurt',
    if (entry)
      'entry': {'node_id': 'n-fi', 'name': 'FI 1', 'country': 'fi', 'city': 'Helsinki'},
    if (exit)
      'exit': {'node_id': 'n-de', 'name': 'DE 1', 'country': 'DE', 'city': 'Frankfurt'},
    'status': 'online',
    'load': 'medium',
    'protocols': ['vless-reality', 'vless-xhttp'],
    'latency_host': '203.0.113.7',
    'latency_port': 443,
    'latency_note': 'entry_only_estimate',
  };

  Map<String, dynamic> profile(String protocol, {String host = '203.0.113.7'}) => {
    'format': 'xray-mobile-v1',
    'payload': {
      'schema_version': 1,
      'protocol': protocol,
      'endpoint': {'host': host, 'port': 443},
      'credentials': protocol == 'hysteria2'
          ? {'password': 'secret'}
          : {'uuid': '00000000-0000-4000-8000-000000000001'},
      'transport': protocol == 'hysteria2'
          ? {'type': 'hysteria', 'obfs': 'salamander', 'obfs_password': 'x'}
          : protocol == 'vless-xhttp'
          ? {'type': 'xhttp', 'path': '/p', 'mode': 'auto'}
          : {'type': 'tcp'},
      'security': protocol == 'hysteria2'
          ? {'type': 'tls', 'server_name': 'example.test'}
          : {
              'type': 'reality',
              'server_name': 'www.cloudflare.com',
              'public_key': 'pk',
              'short_id': 'abcd',
              'fingerprint': 'chrome',
            },
    },
  };

  group('server list', () {
    test('multihop array parses into routes with both ends', () {
      final routes = VPNServer.parseMultihop([route()]);
      expect(routes, hasLength(1));
      final r = routes.single;
      expect(r.isMultihop, isTrue);
      expect(r.id, 'route-1');
      expect(r.routeSlug, 'fi-de');
      expect(r.entry?.country, 'FI');
      expect(r.exit?.country, 'DE');
      expect(r.entry?.label, 'Helsinki');
      // The list shows the exit's flag; the probe address is the entry's.
      expect(r.countryCode, 'DE');
      expect(r.host, '203.0.113.7');
      expect(r.port, 443);
      expect(r.isSelectable, isTrue);
      expect(r.selectionKey, 'route-1');
    });

    test('routes without an id, without an end or marked false are dropped', () {
      final routes = VPNServer.parseMultihop([
        route(id: ''),
        route(id: 'r2', entry: false),
        route(id: 'r3', exit: false),
        route(id: 'r4', multihop: false),
        route(id: 'r5', multihop: null),
        'junk',
      ]);
      expect(routes.map((r) => r.id), ['r5']);
    });

    test('an older panel has no multihop and plain nodes are no routes', () {
      expect(VPNServer.parseMultihop(null), isEmpty);
      final node = VPNServer.fromJson({'id': 'n1', 'countryCode': 'DE'});
      expect(node.isMultihop, isFalse);
      expect(node.entry, isNull);
    });

    test('GET /servers carries nodes and routes; GET /multihop/servers only routes', () async {
      final paths = <String>[];
      final client = _clientFor((options) async {
        paths.add(options.path);
        if (options.path == APIEndpoint.vpnServers) {
          return _json({
            'servers': [
              {'id': 'n1', 'name': 'Node', 'countryCode': 'DE', 'available': true},
            ],
            'multihop': [route()],
          });
        }
        return _json({'servers': [route(id: 'r9')]});
      });
      final service = ColituVPNService(client: client);

      final catalog = await service.catalog();
      expect(catalog.servers.map((s) => s.id), ['n1']);
      expect(catalog.multihop.map((s) => s.id), ['route-1']);
      expect((await service.servers()).single.isMultihop, isFalse);
      expect((await service.multihopServers()).map((s) => s.id), ['r9']);
      expect(paths, contains(APIEndpoint.multihopServers));
    });
  });

  group('route config', () {
    Map<String, dynamic> envelope() => {
      'revision': 7,
      'expires_at': '2099-01-01T00:00:00Z',
      'server': {
        'id': 'route-1',
        'country': 'DE',
        'multihop': true,
        'route_slug': 'fi-de',
        'entry': {'node_id': 'n-fi', 'country': 'FI'},
        'exit': {'node_id': 'n-de', 'country': 'DE'},
      },
      'profile': profile('vless-reality'),
      'candidates': [
        {'protocol': 'vless-xhttp', 'profile': profile('vless-xhttp')},
        {'protocol': 'hysteria2', 'profile': profile('hysteria2')},
      ],
    };

    test('the envelope keeps the route ends', () {
      final config = VPNConfig.fromJson(envelope());
      expect(config.isMultihop, isTrue);
      expect(config.entry?.country, 'FI');
      expect(config.exit?.country, 'DE');
      expect(config.serverId, 'route-1');
      expect(config.outboundCandidates.map((c) => c.protocolType), [
        'vless-reality',
        'vless-xhttp',
        'hysteria2',
      ]);
    });

    test('a normal node envelope is no route', () {
      final json = envelope()..['server'] = {'id': 'n1', 'country': 'DE'};
      expect(VPNConfig.fromJson(json).isMultihop, isFalse);
    });

    test('the route id is escaped in the path', () {
      expect(
        APIEndpoint.multihopRouteConfig('a/b c'),
        '/multihop/routes/a%2Fb%20c/config',
      );
    });

    test('onlyVless drops Hysteria2 and keeps the VLESS order', () {
      final restricted = VPNConfig.fromJson(envelope()).onlyVless();
      expect(restricted, isNotNull);
      expect(restricted!.outboundCandidates.map((c) => c.protocolType), [
        'vless-reality',
        'vless-xhttp',
      ]);
      expect(restricted.protocolType, 'vless-reality');
      expect(restricted.isMultihop, isTrue);
      expect(restricted.exit?.country, 'DE');
    });

    test('onlyVless keeps an all-VLESS config as is and refuses one without VLESS', () {
      final vlessOnly = VPNConfig.fromJson(envelope()..['candidates'] = []);
      expect(identical(vlessOnly.onlyVless(), vlessOnly), isTrue);

      final json = envelope()
        ..['profile'] = profile('hysteria2')
        ..['candidates'] = [
          {'protocol': 'hysteria2', 'profile': profile('hysteria2')},
        ];
      expect(VPNConfig.fromJson(json).onlyVless(), isNull);
    });

    test('routeConfig reads /multihop/routes/{id}/config and reports a missing route', () async {
      String? asked;
      final client = _clientFor((options) async {
        asked = options.path;
        if (options.path.contains('gone')) {
          return _json({
            'error': {'code': 'MULTIHOP_ROUTE_NOT_FOUND', 'message': 'no route'},
          }, statusCode: 404);
        }
        return _json(envelope());
      });
      final service = ColituVPNService(client: client);

      final config = await service.routeConfig('route-1');
      expect(asked, '/multihop/routes/route-1/config');
      expect(config.isMultihop, isTrue);

      await expectLater(
        service.routeConfig('gone'),
        throwsA(
          isA<Exception>().having(
            (e) => (e as dynamic).backendCode,
            'backendCode',
            'MULTIHOP_ROUTE_NOT_FOUND',
          ),
        ),
      );
    });
  });

  group('rotation', () {
    Map<String, dynamic> preferenceJson() => {
      'interval_seconds': 600,
      'countries': ['nl', 'DE', 'de', 'xx1'],
      'intervals': [1800, 300, 600],
      'available_countries': [
        {'country': 'DE', 'in_default': true, 'exits': 1},
        {'country': 'NL', 'in_default': true, 'exits': 2},
        {'country': 'RU', 'in_default': false, 'exits': 1},
        {'country': 'SE', 'in_default': true, 'exits': 0},
      ],
      'protocols': ['vless-reality', 'vless-xhttp'],
      'changes_exit_country': true,
    };

    test('the preference parses', () {
      final p = RotationPreference.fromJson(preferenceJson());
      expect(p.intervalSeconds, 600);
      expect(p.active, isTrue);
      expect(p.countries, ['DE', 'NL']);
      expect(p.intervals, [300, 600, 1800]);
      expect(p.availableCountries, hasLength(4));
      expect(p.availableCountries[2].inDefault, isFalse);
      expect(p.protocols, ['vless-reality', 'vless-xhttp']);
      expect(p.changesExitCountry, isTrue);
    });

    test('a missing or odd answer reads as off', () {
      expect(RotationPreference.fromJson(null).active, isFalse);
      expect(RotationPreference.fromJson('x').intervalSeconds, 0);
      expect(
        RotationPreference.fromJson({'interval_seconds': 123}).intervalSeconds,
        0,
        reason: 'an interval the menu does not offer is read as off',
      );
    });

    test('the status parses with its dates and ends', () {
      final status = RotationStatus.fromJson({
        'active': true,
        'interval_seconds': 600,
        'entry': {'node_id': 'e', 'country': 'FI', 'city': 'Helsinki'},
        'current_exit': {'node_id': 'x', 'name': 'DE 1', 'country': 'DE', 'city': 'Frankfurt'},
        'next_exit': 'Amsterdam',
        'window_started_at': '2026-10-06T10:00:00Z',
        'next_change_at': '2026-10-06T10:10:00Z',
        'exit_set': ['n1'],
        'protocols': ['vless-reality'],
      });
      expect(status.active, isTrue);
      expect(status.currentExit?.label, 'Frankfurt');
      expect(status.nextExit?.name, 'Amsterdam');
      expect(status.nextChangeAt, DateTime.utc(2026, 10, 6, 10, 10));
      expect(status.windowStartedAt, DateTime.utc(2026, 10, 6, 10));
    });

    test('an inactive status keeps the reason and tolerates odd shapes', () {
      final status = RotationStatus.fromJson({
        'active': false,
        'reason': 'not_in_mesh',
        'current_exit': 5,
        'next_change_at': 'soon',
      });
      expect(status.active, isFalse);
      expect(status.reason, 'not_in_mesh');
      expect(status.currentExit, isNull);
      expect(status.nextChangeAt, isNull);
      expect(RotationStatus.fromJson(null).active, isFalse);
    });

    test('GET and PUT /me/rotation and the status call', () async {
      Object? body;
      final seen = <String>[];
      final client = _clientFor((options) async {
        seen.add('${options.method} ${options.path} ${options.queryParameters['node_id'] ?? ''}');
        if (options.method == 'PUT') body = options.data;
        if (options.path == APIEndpoint.rotationStatus) {
          return _json({
            'status': {'active': true, 'next_change_at': '2026-10-06T10:10:00Z'},
          });
        }
        return _json({'rotation': preferenceJson()});
      });
      final service = ColituVPNService(client: client);

      expect((await service.rotation()).intervalSeconds, 600);
      final saved = await service.saveRotation(300, ['nl', 'de', 'DE']);
      expect(saved.intervalSeconds, 600);
      expect(body, {
        'interval_seconds': 300,
        'countries': ['DE', 'NL'],
      });
      expect((await service.rotationStatus('node 1')).active, isTrue);
      expect(seen, contains('GET /me/rotation/status node 1'));
    });

    test('INVALID_PREFERENCE keeps its code for the page', () async {
      final client = _clientFor(
        (options) async => _json({
          'error': {'code': 'INVALID_PREFERENCE', 'message': 'bad'},
        }, statusCode: 400),
      );
      await expectLater(
        ColituVPNService(client: client).saveRotation(300, ['DE']),
        throwsA(
          isA<Exception>().having(
            (e) => (e as dynamic).backendCode,
            'backendCode',
            'INVALID_PREFERENCE',
          ),
        ),
      );
    });

    group('validation', () {
      final available = RotationPreference.fromJson(preferenceJson()).availableCountries;

      test('the interval is off, 5, 10 or 30 minutes', () {
        for (final seconds in [0, 300, 600, 1800]) {
          expect(ColituRotation.isValidInterval(seconds), isTrue, reason: '$seconds');
        }
        for (final seconds in [-1, 1, 60, 900, 3600]) {
          expect(ColituRotation.isValidInterval(seconds), isFalse, reason: '$seconds');
        }
        expect(
          ColituRotation.validate(900, const [], available),
          RotationValidation.invalidInterval,
        );
      });

      test('no countries means the default set', () {
        expect(ColituRotation.validate(600, const [], available), RotationValidation.ok);
        expect(ColituRotation.validate(0, ['DE'], available), RotationValidation.ok);
      });

      test('a chosen set needs at least two countries with exits', () {
        expect(
          ColituRotation.validate(600, ['DE'], available),
          RotationValidation.tooFewCountries,
        );
        expect(
          ColituRotation.validate(600, ['DE', 'SE'], available),
          RotationValidation.tooFewCountries,
          reason: 'SE has no exits',
        );
        expect(
          ColituRotation.validate(600, ['de', 'nl'], available),
          RotationValidation.ok,
        );
        expect(
          ColituRotation.validate(600, ['DE', 'RU'], available),
          RotationValidation.ok,
        );
      });

      test('countries are normalized', () {
        expect(
          ColituRotation.normalizeCountries([' nl ', 'DE', 'de', 'uk', 'x', '12', '']),
          ['DE', 'GB', 'NL'],
        );
      });

      test('the default set leaves out Russia and countries without exits', () {
        expect(ColituRotation.defaultCountries(available), ['DE', 'NL']);
        final p = RotationPreference.fromJson({
          'interval_seconds': 300,
          'available_countries': preferenceJson()['available_countries'],
        });
        expect(ColituRotation.selectedCountries(p), ['DE', 'NL']);
      });

      test('the default checklist is sent as an empty list', () {
        expect(ColituRotation.payloadCountries(['NL', 'DE'], available), isEmpty);
        expect(ColituRotation.payloadCountries(['DE', 'RU'], available), ['DE', 'RU']);
      });
    });

    group('timing', () {
      final now = DateTime.utc(2026, 10, 6, 10);

      test('the status poll waits for the change, never under 60 seconds', () {
        expect(
          ColituRotation.nextPollDelay(now.add(const Duration(minutes: 5)), now),
          const Duration(minutes: 5, seconds: 1),
        );
        expect(
          ColituRotation.nextPollDelay(now.add(const Duration(seconds: 10)), now),
          const Duration(seconds: 60),
        );
        expect(
          ColituRotation.nextPollDelay(now.subtract(const Duration(minutes: 2)), now),
          const Duration(seconds: 60),
        );
        expect(ColituRotation.nextPollDelay(null, now), const Duration(seconds: 60));
        expect(
          ColituRotation.nextPollDelay(now.add(const Duration(hours: 5)), now),
          const Duration(minutes: 35),
        );
      });

      test('the countdown is minutes and seconds', () {
        expect(ColituRotation.formatCountdown(const Duration(minutes: 4, seconds: 7)), '4:07');
        expect(ColituRotation.formatCountdown(const Duration(seconds: 59)), '0:59');
        expect(ColituRotation.formatCountdown(const Duration(minutes: 30)), '30:00');
        expect(ColituRotation.formatCountdown(const Duration(seconds: -4)), '0:00');
      });
    });

    test('VLESS is exactly the two VLESS transports', () {
      expect(ColituRotation.isVless('vless-reality'), isTrue);
      expect(ColituRotation.isVless('vless-xhttp'), isTrue);
      expect(ColituRotation.isVless('hysteria2'), isFalse);
      expect(ColituRotation.isVless('trojan'), isFalse);
      expect(ColituRotation.isVless(null), isFalse);
    });
  });

  group('home chip', () {
    final fixed = DateTime.utc(2026, 10, 6, 12);

    setUp(() async {
      await ColituLoc.I.setLanguage('en', persist: false);
      ColituClock.fix(() => fixed);
    });
    tearDown(() => ColituClock.fix(null));

    test('a multihop route reads Entry FI → Exit DE', () {
      final c = ColituConnectionController()
        ..status = ColituVpnStatus.connected
        ..connectedServer = VPNServer.parseMultihop([route()]).single;
      expect(routeChipText(c), 'Entry FI → Exit DE');
      c.dispose();
    });

    test('a plain tunnel has no chip', () {
      final c = ColituConnectionController()
        ..status = ColituVpnStatus.connected
        ..connectedServer = VPNServer.fromJson({'id': 'n1', 'countryCode': 'DE'});
      expect(routeChipText(c), isNull);
      c.dispose();
    });

    test('a rotating exit shows the current exit and the countdown', () {
      final c = ColituConnectionController()
        ..status = ColituVpnStatus.connected
        ..connectedServer = VPNServer.fromJson({'id': 'n1', 'countryCode': 'FI'})
        ..rotation = RotationPreference.fromJson({'interval_seconds': 600})
        ..rotationStatus = RotationStatus.fromJson({
          'active': true,
          'current_exit': {'country': 'DE', 'city': 'Frankfurt'},
          'next_change_at': fixed.add(const Duration(minutes: 4, seconds: 7)).toIso8601String(),
        });
      expect(routeChipText(c), 'Exit: Frankfurt (DE) · changes in 4:07');

      c.rotationStatus = RotationStatus.fromJson({
        'active': true,
        'current_exit': {'country': 'DE', 'city': 'Frankfurt'},
        'next_change_at': fixed.subtract(const Duration(seconds: 3)).toIso8601String(),
      });
      expect(routeChipText(c), 'Exit: Frankfurt (DE) · changing now');

      // Rotation switched off or a status that is not running: no chip.
      c.rotationStatus = const RotationStatus(active: false, reason: 'not_in_mesh');
      expect(routeChipText(c), isNull);
      c.dispose();
    });
  });

  test('multihop, rotation and manual-config strings exist in every language', () {
    const keys = [
      'multihop.section',
      'multihop.sectionHint',
      'multihop.ping',
      'multihop.sub',
      'multihop.home',
      'multihop.gone',
      'multihop.needsVless',
      'rotation.title',
      'rotation.kicker',
      'rotation.hint',
      'rotation.every',
      'rotation.off',
      'rotation.minutes',
      'rotation.rowOn',
      'rotation.countries',
      'rotation.countriesHint',
      'rotation.err.few',
      'rotation.unavailable',
      'rotation.needsVless',
      'rotation.home',
      'rotation.homeDue',
      'rotation.homeNow',
      'account.manualConfig',
      'account.manualConfigHint',
    ];
    for (final key in keys) {
      expect(ColituLoc.keys, contains(key));
      expect(ColituLoc.valuesOf(key), hasLength(3), reason: key);
    }
  });
}

APIClient _clientFor(Future<ResponseBody> Function(RequestOptions) handler) {
  final dio = _testDio()..httpClientAdapter = _FakeAdapter(handler);
  return APIClient.testing(
    dio: dio,
    refreshDio: _testDio(),
    tokenStore: _FakeTokenStore(),
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

ResponseBody _json(Map<String, dynamic> body, {int statusCode = 200}) {
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
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

class _FakeTokenStore extends Fake implements SecureTokenStore {
  @override
  int get sessionGeneration => 0;

  @override
  Future<AuthTokens?> readTokens() async =>
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1');

  @override
  Future<String?> readDeviceId() async => 'device-1';

  @override
  Future<String?> readDeviceKey() async => 'device-key-1';

  @override
  Future<String?> readConfigEtag() async => null;

  @override
  Future<String?> readLastGoodConfig() async => null;

  @override
  Future<String?> readRuntimePolicy() async => null;
}
