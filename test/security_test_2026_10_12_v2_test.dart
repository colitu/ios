import 'dart:io';

import 'package:colitu_vpn/colitu/services/tunnel_inbounds.dart';
import 'package:colitu_vpn/core/db/database/db_location.dart';
import 'package:colitu_vpn/pages/colitu/privacy_cover.dart';
import 'package:colitu_vpn/service/xray/setting/inbounds_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:colitu_vpn/service/xray/setting/state_writer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('tunnel configuration (IOS-01)', () {
    test('has no password-less ping inbound and no rule for it', () {
      final config = XraySettingState().xrayJson;
      expect(
        config.inbounds!.map((i) => i.tag),
        contains(ColituTunnelInbounds.pingTag),
      );

      ColituTunnelInbounds.stripPing(config);

      expect(
        config.inbounds!.map((i) => i.tag),
        isNot(contains(ColituTunnelInbounds.pingTag)),
      );
      // The TUN inbound the tunnel turns into its SOCKS inbound stays.
      expect(config.inbounds!.map((i) => i.protocol), contains('tun'));
      for (final rule in config.routing!.rules!) {
        expect(rule.ruleTag, isNot(RoutingRuleTag.ping));
        expect(rule.inboundTag ?? const [], isNot(contains('pingIn')));
      }
      // The other rules (DNS through the proxy) are untouched.
      expect(
        config.routing!.rules!.map((r) => r.ruleTag),
        contains(RoutingRuleTag.dnsQuery),
      );
    });

    test('JSON form: drops the ping inbound and rules matching only it', () {
      final config = <String, dynamic>{
        'inbounds': [
          {'tag': 'tunIn', 'protocol': 'tun'},
          {'tag': 'pingIn', 'protocol': 'http', 'listen': '127.0.0.1'},
        ],
        'routing': {
          'rules': [
            {
              'ruleTag': 'ping',
              'inboundTag': ['pingIn'],
              'outboundTag': 'proxy',
            },
            {
              'inboundTag': ['pingIn'],
              'outboundTag': 'proxy',
            },
            {
              'inboundTag': ['tunIn', 'pingIn'],
              'outboundTag': 'proxy',
            },
            {
              'inboundTag': ['tunIn'],
              'port': '53',
              'outboundTag': 'dns-out',
            },
          ],
        },
      };

      ColituTunnelInbounds.stripPingMap(config);

      expect((config['inbounds'] as List).map((i) => i['tag']), ['tunIn']);
      final rules = (config['routing'] as Map)['rules'] as List;
      expect(rules, hasLength(2));
      expect(rules.first['inboundTag'], ['tunIn', 'pingIn']);
    });
  });

  group('latency probe inbound (IOS-01, probe core)', () {
    test('takes a random user name and password, sent by the probe client', () {
      final a = InboundPingState()..port = '41234';
      final b = InboundPingState()..port = '41235';
      final inbound = a.xrayJson;

      expect(inbound.listen, '127.0.0.1');
      expect(inbound.protocol, 'http');
      final accounts = inbound.settings!['accounts'] as List;
      expect(accounts, hasLength(1));
      expect(accounts.single['user'], a.user);
      expect(accounts.single['pass'], a.pass);
      expect(a.user, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a.pass, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a.user, isNot(a.pass));
      expect(b.user, isNot(a.user));
      expect(b.pass, isNot(a.pass));

      final url = Uri.parse(a.proxyUrl);
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, 41234);
      expect(url.userInfo, '${a.user}:${a.pass}');
    });

    test('a raw configuration gets the credentials on its ping inbound', () {
      final auth = InboundPingState()..port = '41236';
      final config = <String, dynamic>{
        'inbounds': [
          {
            'tag': 'pingIn',
            'protocol': 'http',
            'port': '41236',
            'settings': {'timeout': 5},
          },
          {'tag': 'other', 'protocol': 'socks'},
        ],
      };

      auth.protect(config);

      final inbounds = config['inbounds'] as List;
      final settings = inbounds.first['settings'] as Map;
      expect(settings['timeout'], 5);
      expect((settings['accounts'] as List).single, {
        'user': auth.user,
        'pass': auth.pass,
      });
      expect(inbounds.last.containsKey('settings'), isFalse);
    });
  });

  group('open local proxies (I4-03)', () {
    test('a SOCKS inbound counts as open without auth "password"', () {
      Map<String, dynamic> socks(Map<String, dynamic> settings) => {
        'tag': 'x',
        'protocol': 'socks',
        'listen': '127.0.0.1',
        'settings': settings,
      };
      const accounts = [
        {'user': 'u', 'pass': 'p'},
      ];
      expect(
        ColituTunnelInbounds.isOpenLocalProxy(
          socks({'auth': 'password', 'accounts': accounts}),
        ),
        isFalse,
      );
      expect(
        ColituTunnelInbounds.isOpenLocalProxy(
          socks({'auth': 'noauth', 'accounts': accounts}),
        ),
        isTrue,
      );
      expect(
        ColituTunnelInbounds.isOpenLocalProxy(socks({'accounts': accounts})),
        isTrue,
        reason: 'Xray defaults to no authentication',
      );
      expect(
        ColituTunnelInbounds.isOpenLocalProxy(socks({'auth': 'password'})),
        isTrue,
      );
      expect(
        ColituTunnelInbounds.isOpenLocalProxy({
          'protocol': 'http',
          'settings': {'accounts': accounts},
        }),
        isFalse,
      );
      expect(
        ColituTunnelInbounds.isOpenLocalProxy({'protocol': 'http'}),
        isTrue,
      );
      expect(
        ColituTunnelInbounds.isOpenLocalProxy({'protocol': 'tun'}),
        isFalse,
      );
    });

    test('open proxies are dropped from a config, the rest stays', () {
      final config = <String, dynamic>{
        'inbounds': [
          {'tag': 'tunIn', 'protocol': 'tun'},
          {
            'tag': 'open',
            'protocol': 'socks',
            'settings': {
              'auth': 'noauth',
              'accounts': [
                {'user': 'u', 'pass': 'p'},
              ],
            },
          },
          {
            'tag': 'colitu-verify',
            'protocol': 'http',
            'settings': {
              'accounts': [
                {'user': 'u', 'pass': 'p'},
              ],
            },
          },
        ],
      };
      ColituTunnelInbounds.stripOpenProxies(config);
      expect((config['inbounds'] as List).map((i) => i['tag']), [
        'tunIn',
        'colitu-verify',
      ]);
    });
  });

  group('database location (IOS-03)', () {
    late Directory root;
    late String documents;
    late String support;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('colitu_db_');
      documents = p.join(root.path, 'Documents');
      support = p.join(root.path, 'Application Support');
      await Directory(documents).create();
    });

    tearDown(() => root.delete(recursive: true));

    test(
      'moves the old database with its companions and excludes the dir',
      () async {
        await File(p.join(documents, 'db.sqlite')).writeAsString('main');
        await File(p.join(documents, 'db.sqlite-wal')).writeAsString('wal');
        final excluded = <String>[];

        final path = await AppDatabaseLocation.prepare(
          supportDir: support,
          documentsDir: documents,
          exclude: (dir) async => excluded.add(dir),
        );

        expect(path, p.join(support, 'colitu-db', 'db.sqlite'));
        expect(await File(path).readAsString(), 'main');
        expect(await File('$path-wal').readAsString(), 'wal');
        expect(await File(p.join(documents, 'db.sqlite')).exists(), isFalse);
        expect(
          await File(p.join(documents, 'db.sqlite-wal')).exists(),
          isFalse,
        );
        expect(excluded, [p.join(support, 'colitu-db')]);
      },
    );

    test('a leftover old file never replaces the new database', () async {
      final target = p.join(support, 'colitu-db', 'db.sqlite');
      await Directory(p.dirname(target)).create(recursive: true);
      await File(target).writeAsString('new');
      await File(p.join(documents, 'db.sqlite')).writeAsString('stale');

      await AppDatabaseLocation.prepare(
        supportDir: support,
        documentsDir: documents,
        exclude: (_) async => null,
      );

      expect(await File(target).readAsString(), 'new');
      expect(await File(p.join(documents, 'db.sqlite')).exists(), isFalse);
    });

    test('a lone -wal/-shm left in Documents is deleted (I3-04)', () async {
      await File(p.join(documents, 'db.sqlite-wal')).writeAsString('wal');
      await File(p.join(documents, 'db.sqlite-shm')).writeAsString('shm');

      final path = await AppDatabaseLocation.prepare(
        supportDir: support,
        documentsDir: documents,
        exclude: (_) async => null,
      );

      expect(path, p.join(support, 'colitu-db', 'db.sqlite'));
      expect(await File(p.join(documents, 'db.sqlite-wal')).exists(), isFalse);
      expect(await File(p.join(documents, 'db.sqlite-shm')).exists(), isFalse);
    });

    test(
      'a failed move keeps the old database whole and opens it (I3-04)',
      () async {
        await File(p.join(documents, 'db.sqlite')).writeAsString('main');
        await File(p.join(documents, 'db.sqlite-wal')).writeAsString('wal');
        await File(p.join(documents, 'db.sqlite-shm')).writeAsString('shm');
        // A directory where the main file should go: the companions move
        // first, then the main file fails, and everything goes back.
        final from = p.join(documents, 'db.sqlite');
        final to = p.join(support, 'colitu-db', 'db.sqlite');
        await Directory(to).create(recursive: true);

        final path = await AppDatabaseLocation.migrate(from: from, to: to);

        expect(path, from);
        expect(await File(from).readAsString(), 'main');
        expect(await File('$from-wal').readAsString(), 'wal');
        expect(await File('$from-shm').readAsString(), 'shm');
        expect(await File('$to-wal').exists(), isFalse);
      },
    );

    test('a fresh install just gets the new location', () async {
      final path = await AppDatabaseLocation.prepare(
        supportDir: support,
        documentsDir: documents,
        exclude: (_) async => null,
      );
      expect(await Directory(p.dirname(path)).exists(), isTrue);
      expect(await File(path).exists(), isFalse);
    });
  });

  group('app switcher cover (IOS-04)', () {
    test('covers in every state but resumed', () {
      for (final state in AppLifecycleState.values) {
        expect(
          ColituPrivacyCover.coversIn(state),
          state != AppLifecycleState.resumed,
        );
      }
    });

    testWidgets('shows the brand screen while inactive', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: ColituPrivacyCover(child: Text('secret@example.test')),
        ),
      );
      const cover = ValueKey('colituPrivacyCover');
      expect(find.byKey(cover), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(cover), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(cover), findsNothing);
    });
  });
}
