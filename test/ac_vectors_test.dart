import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/colitu_vpn_config_adapter.dart';
import 'package:colitu_vpn/colitu/services/recovery_set.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared Adaptive Connect test vectors (canonical copy in the colitu-csl
/// repo, engine/testdata/ac-vectors; the same files run in the Android,
/// Windows and Linux apps and in the Go engine). Every case must give exactly
/// its "expect".
Map<String, dynamic> _load(String name) =>
    jsonDecode(File('test/ac-vectors/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('ranking', () {
    final doc = _load('ranking.json');
    final now = DateTime.fromMillisecondsSinceEpoch(doc['now_ms'] as int);
    final network = doc['network'] as String;
    final failures = <String>[];
    for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>()) {
      final servers = [
        for (final s in (c['servers'] as List).cast<Map<String, dynamic>>())
          VPNServer.fromJson({
            'id': s['id'],
            'name': s['id'],
            'countryCode': s['country'],
            'available': s['available'] ?? true,
          }),
      ];
      final pings = <String, ColituPing>{
        for (final e in (c['pings'] as Map<String, dynamic>).entries)
          e.key: ColituPing(
            ms: (e.value as Map)['ms'] as int?,
            at: now.subtract(Duration(seconds: (e.value as Map)['age_s'] as int)),
            network: (e.value as Map)['network'] as String? ?? network,
          ),
      };
      final memory = ColituAdaptiveMemory();
      final lastGood = c['last_good'] as String?;
      if (lastGood != null) {
        memory.recordSuccess(network, lastGood, null, now.subtract(const Duration(minutes: 5)));
      }
      for (final p in (c['penalized'] as List).cast<Map<String, dynamic>>()) {
        memory.penalize(network, p['id'] as String, now.subtract(Duration(seconds: p['age_s'] as int)));
      }
      final got = [
        for (final s in rankServers(
          servers,
          pings: pings,
          memory: memory,
          network: network,
          clientCountry: c['client_country'] as String?,
          now: now,
        ))
          s.selectionKey,
      ];
      final expected = (c['expect'] as List).cast<String>();
      if (got.join(',') != expected.join(',')) {
        failures.add('${c['name']}: expected $expected, got $got');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  List<String> strs(Object? v) => (v as List).cast<String>();

  // base_order: stable sort by transportRankFor (stalled ones excluded).
  List<String> baseOrder(List<String> offered, Set<String> stalled) {
    final order = List<int>.generate(offered.length, (i) => i)
      ..sort((a, b) {
        final ra = ColituVPNConfigAdapter.transportRankFor(offered[a], excluded: stalled);
        final rb = ColituVPNConfigAdapter.transportRankFor(offered[b], excluded: stalled);
        return ra != rb ? ra.compareTo(rb) : a.compareTo(b);
      });
    return [for (final i in order) offered[i]];
  }

  List<Map<String, dynamic>> cases(Map<String, dynamic> doc, String key) =>
      (doc[key] as List).cast<Map<String, dynamic>>();

  test('transport base_order', () {
    final failures = <String>[];
    for (final c in cases(_load('transport.json'), 'base_order')) {
      final got = baseOrder(strs(c['offered']), strs(c['stalled']).toSet());
      if (got.join(',') != strs(c['expect']).join(',')) {
        failures.add('${c['name']}: expected ${c['expect']}, got $got');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('transport hinted_start', () {
    final failures = <String>[];
    for (final c in cases(_load('transport.json'), 'hinted_start')) {
      final stalled = strs(c['stalled']).toSet();
      final got = colituHintedStart<String>(
        strs(c['offered']),
        protocolOf: (p) => p,
        preferred: strs(c['preferred']),
        stalled: stalled,
        lastGood: c['last_good'] as String?,
        rank: (rest) => baseOrder(rest, stalled),
      )?.order;
      final expected = c['expect'] == null ? null : strs(c['expect']);
      if (got?.join(',') != expected?.join(',')) {
        failures.add('${c['name']}: expected $expected, got $got');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('transport marks_ignored', () {
    final failures = <String>[];
    for (final c in cases(_load('transport.json'), 'marks_ignored')) {
      final got = colituStallMarks(strs(c['offered']), strs(c['stalled']).toSet())
          .soft
          .isNotEmpty;
      if (got != c['expect']) {
        failures.add('${c['name']}: expected ${c['expect']}, got $got');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('hints parse', () {
    final failures = <String>[];
    for (final c in cases(_load('hints.json'), 'parse')) {
      final hints = ColituNetworkHints.fromServers({
        'network_hints': {'blocked': c['blocked'], 'preferred': c['preferred']},
      }, 'net-1')!;
      final gotBlocked = hints.blocked.toList();
      final expBlocked = strs(c['expect_blocked']);
      final expPreferred = strs(c['expect_preferred']);
      if (gotBlocked.join(',') != expBlocked.join(',')) {
        failures.add('${c['name']}: blocked expected $expBlocked, got $gotBlocked');
      }
      if (hints.preferred.join(',') != expPreferred.join(',')) {
        failures.add('${c['name']}: preferred expected $expPreferred, got ${hints.preferred}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  group('recovery', () {
    final doc = _load('recovery.json');
    final now = DateTime.parse(doc['now'] as String).toUtc();

    Map<String, Object?> envelope(String? id) => {
      'revision': 1,
      'expires_at': '2099-01-01T00:00:00Z',
      'server': {'id': ?id, 'country': 'DE'},
      'profile': {
        'format': 'xray-mobile-v1',
        'payload': {
          'schema_version': 1,
          'protocol': 'trojan',
          'endpoint': {'host': '${id ?? "x"}.example.test', 'port': 443},
          'credentials': {'password': 'secret'},
          'transport': {'type': 'tcp'},
          'security': {'type': 'tls', 'server_name': '${id ?? "x"}.example.test'},
        },
      },
    };

    ColituRecoverySet? setOf(Object? generated, Object? until, List<Object?> ids) =>
        ColituRecoverySet.parse({
          'generated_at': generated,
          'recovery_until': until,
          'configs': [for (final id in ids) envelope(id as String?)],
        });

    test('decide', () {
      final failures = <String>[];
      for (final c in cases(doc, 'decide')) {
        final until = (c['expired'] as bool)
            ? now.subtract(const Duration(days: 1))
            : now.add(const Duration(days: 7));
        final set = setOf(
          now.subtract(const Duration(days: 7)).toIso8601String(),
          until.toIso8601String(),
          ['a'],
        );
        final Object apiError = (c['api_unreachable'] as bool)
            ? TimeoutException('api')
            : const APIException(APIErrorCode.backendUnavailable, 'x', statusCode: 503);
        final got = ColituRecovery.decide(
          automatic: c['automatic'] as bool,
          multihop: c['multihop'] as bool,
          apiError: apiError,
          cacheUsable: c['cache_usable'] as bool,
          set: set,
          now: now,
        ).name;
        if (got != c['expect']) {
          failures.add('${c['name']}: expected ${c['expect']}, got $got');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('refresh_due', () {
      final failures = <String>[];
      DateTime? ago(Object? min) =>
          min == null ? null : now.subtract(Duration(minutes: min as int));
      for (final c in cases(doc, 'refresh_due')) {
        final got = ColituRecovery.refreshDue(
          generatedAt: ago(c['generated_age_min']),
          lastAttempt: ago(c['attempt_age_min']),
          now: now,
        );
        if (got != c['expect']) {
          failures.add('${c['name']}: expected ${c['expect']}, got $got');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('set_parse', () {
      final failures = <String>[];
      for (final c in cases(doc, 'set_parse')) {
        final set = setOf(c['generated_at'], c['recovery_until'], c['servers'] as List);
        final got = set?.configs.map((e) => e.serverId).toList();
        final expected = c['expect'] == null ? null : strs(c['expect']);
        if (got?.join(',') != expected?.join(',')) {
          failures.add('${c['name']}: expected $expected, got $got');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('next_server', () {
      final failures = <String>[];
      for (final c in cases(doc, 'next_server')) {
        final set = setOf('2026-10-16T00:00:00Z', '2026-10-30T00:00:00Z', strs(c['servers']))!;
        final got = ColituRecovery.next(set, strs(c['failed']))?.serverId;
        if (got != c['expect']) {
          failures.add('${c['name']}: expected ${c['expect']}, got $got');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  });
}
