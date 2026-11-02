import 'dart:convert';

import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/colitu_ac_events.dart';
import 'package:colitu_vpn/colitu/services/colitu_lm.dart';
import 'package:colitu_vpn/colitu/services/colitu_lm_engine.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/engine_journal.dart';
import 'package:flutter_test/flutter_test.dart';

String _uuid(String tail) => '00000000-0000-4000-8000-${tail.padLeft(12, '0')}';

VPNServer _server(
  String tail,
  String country, {
  String? name,
  String? host,
  int? port = 443,
  bool whitelist = false,
  List<String> protocols = const ['vless-reality'],
  bool multihop = false,
  String? entry,
}) => VPNServer(
  id: _uuid(tail),
  name: name ?? tail,
  country: country,
  flagCode: country,
  status: 'online',
  available: true,
  locked: false,
  isPremium: false,
  isFree: true,
  isRecommended: false,
  host: host ?? '$tail.example.test',
  port: port,
  whitelistOk: whitelist,
  protocols: protocols,
  isMultihop: multihop,
  entry: multihop ? RouteEndpoint(country: entry) : null,
  exit: multihop ? RouteEndpoint(country: country) : null,
);

const _model = ColituLmModel(version: 1, country: 'RU', explore: 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('whitelist rule', () {
    test('foreign <= 1/5 and domestic >= 2/4', () {
      for (final (f, d, want) in [
        (0, 4, true),
        (1, 2, true),
        (2, 4, false),
        (1, 1, false),
        (0, 0, false),
        (5, 4, false),
      ]) {
        expect(ColituWhitelist.isWhitelist(f, d), want, reason: '$f/$d');
        expect(ColituWhitelistCheck(f, 5, d, 4, 100).whitelist, want);
      }
    });

    test('the mode ends only when the foreign set works again', () {
      expect(ColituWhitelist.nextState(false, const ColituWhitelistCheck(0, 5, 3, 4, 900)), isTrue);
      // Nothing answers at all: no network, the mode stays.
      expect(ColituWhitelist.nextState(true, const ColituWhitelistCheck(0, 5, 0, 4, 4000)), isTrue);
      expect(ColituWhitelist.nextState(true, const ColituWhitelistCheck(1, 5, 4, 4, 300)), isTrue);
      expect(ColituWhitelist.nextState(true, const ColituWhitelistCheck(4, 5, 4, 4, 300)), isFalse);
      expect(ColituWhitelist.nextState(false, const ColituWhitelistCheck(5, 5, 4, 4, 300)), isFalse);
      expect(const ColituWhitelistCheck(1, 5, 3, 4, 10).flag(true), 'on:f1/5:d3/4');
    });

    test('whitelist_probe parses and falls back to the default', () {
      final probe = ColituWhitelist.parseProbe(
        jsonDecode('{"ru":["ya.ru","VK.com","bad host","-x.ru"],"XYZ":["a.b"],"TR":[]}'),
      );
      expect(probe.keys, ['RU']);
      expect(probe['RU'], ['ya.ru', 'vk.com']);
      expect(ColituWhitelist.parseProbe(null), isEmpty);
      expect(ColituWhitelist.domesticSet(probe, 'ru'), ['ya.ru', 'vk.com']);
      expect(ColituWhitelist.domesticSet(null, 'RU'), ['ya.ru', 'vk.com', 'gosuslugi.ru', 'mail.ru']);
      expect(ColituWhitelist.domesticSet(null, 'TR'), isEmpty);
      expect(ColituWhitelist.domesticSet(probe, null), isEmpty);
    });

    test('foreign set: 3 neutral hosts on 443 + 2 Colitu nodes on their ping port', () {
      final servers = [
        _server('1', 'RU', host: 'ru.example'),
        _server('2', 'FI', name: 'Finlandiya (Köprü)', host: 'bridge.example'),
        _server('3', 'DE', host: 'wl.example', whitelist: true),
        _server('4', 'NL', host: 'nl.example', port: 8443),
        _server('5', 'DE', host: 'de.example', port: 2083),
        _server('6', 'SE', host: 'se.example'),
        _server('7', 'PL', host: 'bad.example', port: 22),
      ];
      final pings = {_uuid('4'): 90, _uuid('5'): 40, _uuid('7'): 10};
      final set = ColituWhitelist.foreignSet(servers, (s) => pings[s.id]);
      expect(set, hasLength(5));
      expect([for (final t in set.take(3)) t.host], ColituWhitelist.neutralForeignHosts);
      expect(set.take(3).every((t) => t.port == 443), isTrue);
      expect([for (final t in set.skip(3)) '${t.host}:${t.port}'], ['de.example:2083', 'nl.example:8443']);
    });

    test('check counts both sets in parallel on the right ports', () async {
      final seen = <String>[];
      final check = await ColituWhitelist.check(
        [(host: 'www.google.com', port: 443), (host: 'de.example', port: 2083)],
        ['ya.ru', 'vk.com', 'mail.ru'],
        reachable: (host, port, timeout) async {
          seen.add('$host:$port');
          return host.endsWith('.ru') || host == 'vk.com';
        },
      );
      expect(seen, containsAll(['de.example:2083', 'ya.ru:443', 'vk.com:443']));
      expect(check.foreignOk, 0);
      expect(check.foreignTotal, 2);
      expect(check.domesticOk, 3);
      expect(check.whitelist, isTrue);
    });

    test('the whitelist ac-event', () {
      final event = ColituAcEvents.whitelist(
        on: true, foreignOk: 7, foreignTotal: 5, domesticOk: 3, domesticTotal: 4, ms: 1200,
      )!;
      expect(event['kind'], 'whitelist');
      expect(event['state'], 'on');
      expect(event['foreign_ok'], 5);
      expect(event.containsKey('node_id'), isFalse);
      expect(
        ColituAcEvents.whitelist(on: false, foreignOk: 0, foreignTotal: 0, domesticOk: 0, domesticTotal: 4, ms: 1),
        isNull,
      );
    });
  });

  group('bridges and Russian servers', () {
    test('a bridge is a name suffix or a route entering in the network country', () {
      expect(ColituLmPlanner.isBridgeName('Finlandiya (Köprü)'), isTrue);
      expect(ColituLmPlanner.isBridgeName('Финляндия (Мост)'), isTrue);
      expect(ColituLmPlanner.isBridgeName('Finland (Bridge)'), isTrue);
      expect(ColituLmPlanner.isBridgeName('Finland'), isFalse);
      final bridge = _server('2', 'FI', name: 'Finlandiya (Köprü)');
      expect(ColituLmPlanner.countries(bridge), ('RU', 'FI'));
      expect(ColituLmPlanner.isBridge(bridge), isTrue);
      expect(ColituLmPlanner.exitsInRussia(bridge), isFalse);
      final route = _server('9', 'DE', multihop: true, entry: 'RU');
      expect(ColituLmPlanner.isBridge(route, networkCountry: 'RU'), isTrue);
      expect(ColituLmPlanner.isBridge(route, networkCountry: 'TR'), isFalse);
      expect(ColituLmPlanner.exitsInRussia(_server('1', 'RU')), isTrue);
    });

    test('RU servers listed only for Russian UI or a network in Russia', () {
      final ru = _server('1', 'RU');
      final de = _server('3', 'DE');
      expect(ColituRuServers.visible(ru, appLanguage: 'tr', networkCountry: 'TR'), isFalse);
      expect(ColituRuServers.visible(ru, appLanguage: 'ru', networkCountry: 'TR'), isTrue);
      expect(ColituRuServers.visible(ru, appLanguage: 'en', networkCountry: 'ru'), isTrue);
      expect(ColituRuServers.visible(de, appLanguage: 'tr', networkCountry: 'TR'), isTrue);
    });

    test('a plain RU server is never chosen automatically, a bridge may be', () {
      final servers = [
        _server('1', 'RU'),
        _server('2', 'FI', name: 'Finlandiya (Köprü)'),
      ];
      final pairs = ColituLmPlanner.candidates(
        servers,
        latencyMs: (s) => s.countryCode == 'RU' ? 5 : 300,
        history: (id, p) => const [],
      );
      final decision = ColituLm.decide(
        ColituLmInput(
          model: _model,
          engineEnabled: true,
          candidates: [for (final p in pairs) p.candidate],
        ),
      );
      final order = ColituLmPlanner.order(decision, pairs);
      expect(order.servers.map((s) => s.id), [_uuid('2')]);
      expect(order.lead, 'vless-reality');
    });

    test('in whitelist mode only whitelist servers, bridges first', () {
      final servers = [
        _server('1', 'RU', whitelist: true),
        _server('2', 'FI', name: 'Finlandiya (Köprü)', whitelist: true),
        _server('3', 'DE'),
      ];
      int? ping(VPNServer s) => {_uuid('1'): 10, _uuid('2'): 500, _uuid('3'): 5}[s.id];
      final pairs = ColituLmPlanner.candidates(servers, latencyMs: ping, history: (id, p) => const []);
      final decision = ColituLm.decide(
        ColituLmInput(
          model: _model,
          engineEnabled: true,
          whitelistMode: true,
          candidates: [for (final p in pairs) p.candidate],
        ),
      );
      expect(
        ColituLmPlanner.order(decision, pairs).servers.map((s) => s.id),
        [_uuid('2'), _uuid('1')],
      );
      // No model yet: the AC 3 fallback keeps to the same servers.
      expect(
        ColituLmPlanner.whitelistOrder(servers, ping).map((s) => s.id),
        [_uuid('2'), _uuid('1')],
      );
    });
  });

  group('device history and model store', () {
    test('outcomes per network, server and protocol survive encoding', () {
      final now = DateTime.utc(2026, 11, 2, 12);
      final saved = <String>[];
      final history = ColituLmHistory(save: saved.add);
      history.record('wifi|TR-AS1', _uuid('3'), 'trojan', true, now.subtract(const Duration(hours: 3)));
      history.record('wifi|TR-AS1', _uuid('3'), 'trojan', false, now);
      history.record('cellular|TR-AS2', _uuid('3'), 'trojan', true, now);
      expect(saved, hasLength(3));
      expect(saved.last, isNot(contains('TR-AS1')));
      final again = ColituLmHistory()..load(saved.last, now);
      final outcomes = again.outcomes('wifi|TR-AS1', _uuid('3'), 'trojan', now);
      expect([for (final o in outcomes) (o.ageH, o.ok)], [(3.0, true), (0.0, false)]);
      expect(again.outcomes('wifi|TR-AS1', _uuid('3'), 'hysteria2', now), isEmpty);
      // Older than 21 days: dropped.
      expect((ColituLmHistory()..load(saved.last, now.add(const Duration(days: 22)))).count, 0);
    });

    test('the model is fresh for 1 h and refetched at most every 10 min', () {
      final now = DateTime.utc(2026, 11, 2, 12);
      final store = ColituLmModelStore();
      expect(store.takeFetchSlot(now, 'RU'), isTrue);
      expect(store.takeFetchSlot(now.add(const Duration(minutes: 5)), 'RU'), isFalse);
      store.set(_model, now);
      expect(store.takeFetchSlot(now.add(const Duration(minutes: 30)), 'RU'), isFalse);
      expect(store.takeFetchSlot(now.add(const Duration(minutes: 30)), 'TR'), isTrue);
      expect(store.takeFetchSlot(now.add(const Duration(minutes: 61)), 'RU'), isTrue);
      // Offline the last model stays in use, however old.
      expect(store.model, same(_model));
      expect(store.ageH(now.add(const Duration(minutes: 90))), 1.5);
      final loaded = ColituLmModelStore()..load(store.encode());
      expect(loaded.model?.country, 'RU');
      expect(loaded.fetchedAt, now);
    });

    test('city and prior_scope are parsed, kept and leave the math alone', () {
      final json = {
        'version': 1,
        'country': 'RU',
        'city': 'Moscow',
        'priors': {
          'RU': {
            _uuid('3'): {
              'vless-reality': [8.0, 2.0],
            },
            _uuid('4'): {
              '*': [3.0, 17.0],
            },
          },
        },
        'prior_scope': {
          'RU': {
            _uuid('3'): {'scope': 'city', 'city': 'Moscow'},
            _uuid('4'): {'scope': 'country', 'city': 'ignored'},
            'bad': {'scope': 'region'},
          },
        },
      };
      final model = ColituLmModel.fromJson(json)!;
      expect(model.city, 'Moscow');
      expect(model.priorScope['RU']![_uuid('3')], (scope: 'city', city: 'Moscow'));
      expect(model.priorScope['RU']![_uuid('4')], (scope: 'country', city: null));
      expect(model.priorScope['RU']!.containsKey('bad'), isFalse);
      expect(model.priorScopeSummary, 'city Moscow; RU 1 city (Moscow), 1 country');
      final again = ColituLmModel.fromJson(jsonDecode(jsonEncode(model.toJson())))!;
      expect(again.priorScopeSummary, model.priorScopeSummary);
      // Same scores with or without the informational fields.
      final plain = ColituLmModel.fromJson({...json, 'city': null, 'prior_scope': null})!;
      expect(plain.priorScopeSummary, isEmpty);
      List<double> scores(ColituLmModel m) => [
        for (final c in ColituLm.decide(
          ColituLmInput(
            model: m,
            engineEnabled: true,
            country: 'RU',
            candidates: [
              ColituLmCandidate(nodeId: _uuid('3'), protocol: 'vless-reality', latencyMs: 90),
              ColituLmCandidate(nodeId: _uuid('4'), protocol: 'trojan', latencyMs: 40),
            ],
          ),
        ).candidates)
          c.score,
      ];
      expect(scores(model), scores(plain));
    });

    test('the journal keeps the last 300 records, oldest first', () {
      final journal = ColituEngineJournal();
      for (var i = 0; i < 305; i++) {
        journal.add(ColituEngineJournal.outcome, {'i': i});
      }
      final records = journal.snapshot();
      expect(records, hasLength(300));
      expect((records.first.data as Map)['i'], 5);
      expect((records.last.data as Map)['i'], 304);
      expect((jsonDecode(journal.toJson()) as List).first['kind'], 'outcome');
    });
  });

  group('controller', () {
    tearDown(() => ColituAc4Switch.setRemote(false));

    final servers = [
      _server('1', 'RU', whitelist: true),
      _server('2', 'FI', name: 'Finlandiya (Köprü)', whitelist: true),
      _server('3', 'DE'),
      _server('4', 'NL'),
    ];

    test('switch off: the AC 3 order, unchanged even with a model and whitelist mode', () {
      ColituAc4Switch.setRemote(false);
      final c = ColituConnectionController()..servers = servers;
      addTearDown(c.dispose);
      c.debugSetAcModel(_model, DateTime.now());
      c.debugWhitelistMode = true;
      final ac3 = rankServers(
        servers,
        pings: const {},
        memory: ColituAdaptiveMemory(),
        network: c.networkKey,
        now: DateTime.now(),
      );
      expect(c.rankedServers.map((s) => s.id), ac3.map((s) => s.id));
      expect(c.rankedServers.map((s) => s.id), isNot(contains(_uuid('1'))));
    });

    test('switch on with a model: the model orders, RU never chosen', () {
      ColituAc4Switch.setRemote(true);
      final c = ColituConnectionController()..servers = servers;
      addTearDown(c.dispose);
      c.debugSetAcModel(_model, DateTime.now());
      expect(c.rankedServers.map((s) => s.id), isNot(contains(_uuid('1'))));
      c.debugWhitelistMode = true;
      expect(c.rankedServers.map((s) => s.id), [_uuid('2'), _uuid('1')]);
    });

    test('switch on without a model: AC 3 order, whitelist mode keeps to its servers', () {
      ColituAc4Switch.setRemote(true);
      final c = ColituConnectionController()..servers = servers;
      addTearDown(c.dispose);
      expect(c.acModel, isNull);
      expect(c.rankedServers.map((s) => s.id), isNot(contains(_uuid('1'))));
      c.debugWhitelistMode = true;
      expect(c.rankedServers.map((s) => s.id), [_uuid('2'), _uuid('1')]);
    });

    test('a whitelist check turns the mode on with a notice; off with the switch', () async {
      final c = ColituConnectionController()
        ..servers = servers
        ..debugClientCountry = 'RU';
      addTearDown(c.dispose);
      var foreignUp = false;
      c.whitelistReachable = (host, port, timeout) async =>
          host.endsWith('.ru') || host == 'vk.com' || foreignUp;

      ColituAc4Switch.setRemote(false);
      await c.checkWhitelist('test', afterFailures: false);
      expect(c.whitelistMode, isFalse);

      ColituAc4Switch.setRemote(true);
      await c.checkWhitelist('test', afterFailures: false);
      expect(c.whitelistMode, isTrue);
      expect(c.notice, ColituLoc.I['notice.whitelistOn']);
      expect(
        ColituEngineJournal.instance.snapshot().last.kind,
        ColituEngineJournal.whitelist,
      );

      foreignUp = true;
      await c.checkWhitelist('re-check', afterFailures: false);
      expect(c.whitelistMode, isFalse);
    });

    test('Russian servers leave the list unless the app speaks Russian', () async {
      final c = ColituConnectionController()
        ..servers = servers
        ..debugClientCountry = 'TR';
      addTearDown(c.dispose);
      final before = ColituLoc.I.language;
      addTearDown(() => ColituLoc.I.setLanguage(before, persist: false));
      await ColituLoc.I.setLanguage('tr', persist: false);
      expect(c.visibleServers.map((s) => s.id), isNot(contains(_uuid('1'))));
      await ColituLoc.I.setLanguage('ru', persist: false);
      expect(c.visibleServers.map((s) => s.id), contains(_uuid('1')));
    });
  });
}
