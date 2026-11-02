import 'dart:convert';

import 'package:colitu_vpn/colitu/services/diagnostics_engine.dart';
import 'package:colitu_vpn/colitu/services/engine_journal.dart';
import 'package:flutter_test/flutter_test.dart';

const _node = '00000000-0000-4000-8000-0000000000de';

int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;

List<ColituEngineJournalEntry> _journal(void Function(ColituEngineJournal j) fill) {
  final journal = ColituEngineJournal();
  fill(journal);
  return journal.snapshot();
}

void main() {
  final start = DateTime.utc(2026, 11, 2, 12);

  test('schema: the DiagnosticsEngine fields, newest first', () {
    final engine = ColituDiagnosticsEngine.build(
      journal: _journal((j) {
        j.add(ColituEngineJournal.decision, {'engine': 'ac4', 'reason': 'score', 'n': 1}, at: start);
        j.add(ColituEngineJournal.outcome, {'node_id': _node, 'outcome': 'ok'}, at: start.add(const Duration(seconds: 1)));
        j.add(ColituEngineJournal.pingRound, {'total': 4, 'failed': 1}, at: start);
        j.add(ColituEngineJournal.hidden, {'reason': 'unreachable_vpn_off', 'servers': [_node], 'of': 4}, at: start);
        j.add(ColituEngineJournal.whitelist, {'state': 'on', 'flag': 'on:f0/5:d4/4'}, at: start);
      }),
      modelVersion: '1 2026-11-02T03:00:00Z',
      flags: {'ac_engine_4': true, 'whitelist_mode': false},
      hiddenNow: ['00000000-0000-4000-8000-00000000004e'],
      now: start,
    );
    expect(engine.keys.toSet(), {
      'model_version', 'flags', 'decisions', 'ping_rounds', 'hidden_servers', 'whitelist_checks',
    });
    expect(engine['model_version'], '1 2026-11-02T03:00:00Z');
    expect(engine['flags'], {'ac_engine_4': true, 'whitelist_mode': false});
    final decisions = engine['decisions'] as List;
    expect([for (final d in decisions) d['kind']], ['outcome', 'decision']);
    expect(decisions.last['reason'], 'score');
    expect(decisions.last['at'], '2026-11-02T12:00:00.000Z');
    expect((engine['ping_rounds'] as List).single['failed'], 1);
    expect([for (final h in engine['hidden_servers'] as List) h['reason']], ['hidden_now', 'unreachable_vpn_off']);
    expect((engine['hidden_servers'] as List).last['node_id'], _node);
    expect((engine['whitelist_checks'] as List).single['flag'], 'on:f0/5:d4/4');
    expect(() => jsonEncode(engine), returnsNormally);
  });

  test('limits: item counts and flags', () {
    final journal = <ColituEngineJournalEntry>[
      for (var i = 0; i < 400; i++)
        ColituEngineJournalEntry(start.add(Duration(seconds: i)), ColituEngineJournal.decision, {'i': i}),
      for (var i = 0; i < 80; i++)
        ColituEngineJournalEntry(start, ColituEngineJournal.pingRound, {'i': i}),
      for (var i = 0; i < 30; i++)
        ColituEngineJournalEntry(start, ColituEngineJournal.hidden, {
          'servers': [for (var k = 0; k < 10; k++) 'node-$i-$k-xxxxxxxx'],
        }),
      for (var i = 0; i < 150; i++)
        ColituEngineJournalEntry(start, ColituEngineJournal.whitelist, {'i': i}),
    ];
    final engine = ColituDiagnosticsEngine.build(
      journal: journal,
      flags: {for (var i = 0; i < 100; i++) 'f$i': i},
      modelVersion: 'v' * 100,
    );
    final decisions = engine['decisions'] as List;
    expect(decisions, hasLength(300));
    expect(decisions.first['i'], 399, reason: 'newest first');
    expect(decisions.last['i'], 100, reason: 'the oldest dropped');
    expect(engine['ping_rounds'] as List, hasLength(60));
    expect(engine['hidden_servers'] as List, hasLength(200));
    expect(engine['whitelist_checks'] as List, hasLength(100));
    expect((engine['flags'] as Map), hasLength(64));
    expect((engine['model_version'] as String).length, 64);
  });

  test('a decision over 4 KiB keeps its best ranked candidates', () {
    final candidates = [
      for (var i = 0; i < 60; i++)
        {'node_id': '00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}', 'protocol': 'vless-reality', 'pad': 'x' * 60},
    ];
    final engine = ColituDiagnosticsEngine.build(
      journal: _journal((j) {
        j.add(ColituEngineJournal.decision, {
          'engine': 'ac4',
          'candidates': candidates,
          'ranking': [42, 7, 3],
        });
        j.add(ColituEngineJournal.pingRound, {'blob': 'y' * 5000});
      }),
    );
    final decision = (engine['decisions'] as List).single as Map;
    expect(_bytes(decision), lessThanOrEqualTo(ColituDiagnosticsEngine.maxItemBytes));
    final kept = decision['candidates'] as List;
    expect([for (final c in kept.take(3)) c['index']], [42, 7, 3]);
    expect(decision['candidates_trimmed'], 60 - kept.length);
    expect(engine['ping_rounds'], isEmpty, reason: 'an item over 4 KiB is dropped');
  });

  test('the whole stays within 192 KiB, the oldest decisions go first', () {
    final journal = [
      for (var i = 0; i < 300; i++)
        ColituEngineJournalEntry(start.add(Duration(seconds: i)), ColituEngineJournal.decision, {'i': i, 'pad': 'z' * 1500}),
      ColituEngineJournalEntry(start, ColituEngineJournal.whitelist, {'state': 'on'}),
    ];
    final engine = ColituDiagnosticsEngine.build(journal: journal);
    expect(_bytes(engine), lessThanOrEqualTo(ColituDiagnosticsEngine.maxTotalBytes));
    final decisions = engine['decisions'] as List;
    expect(decisions.length, lessThan(300));
    expect(decisions.first['i'], 299);
    expect(engine['whitelist_checks'] as List, hasLength(1));
  });

  test('masking: sites, foreign addresses and secrets; Colitu hosts and node ids stay', () {
    final engine = ColituDiagnosticsEngine.build(
      journal: _journal((j) {
        j.add(ColituEngineJournal.decision, {
          'reason': 'score',
          'note': 'dial tcp:youtube.com:443 failed, dial tcp:93.184.216.34:53 failed, dial tcp:de1.example.test:443 ok, user me@example.org',
          'candidates': [{'node_id': _node}],
        });
      }),
      flags: {'network_country': 'TR', 'probe': 'dial tcp:instagram.com:443'},
      knownHosts: ['de1.example.test'],
    );
    final text = jsonEncode(engine);
    expect(text, isNot(contains('youtube.com')));
    expect(text, isNot(contains('93.184.216.34')));
    expect(text, isNot(contains('instagram.com')));
    expect(text, isNot(contains('me@example.org')));
    expect(text, contains('de1.example.test'));
    expect(text, contains(_node));
    expect(text, contains('"network_country":"TR"'));
  });
}
