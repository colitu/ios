import 'dart:convert';
import 'dart:io';

import 'package:colitu_vpn/colitu/services/colitu_lm.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adaptive Connect 4 "Colitu LM": the shared vectors (colitu-panel
/// docs/ac-model-vectors.json; the same file runs in the Go reference and
/// every app) must come out to 1e-9.
void main() {
  final doc =
      jsonDecode(File('test/fixtures/ac-model-vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final tolerance = (doc['tolerance'] as num).toDouble();

  test('xorshift32 outputs and floats', () {
    final vectors = doc['rng'] as List;
    expect(vectors, hasLength(3));
    for (final v in vectors.cast<Map>()) {
      final seed = (v['seed'] as num).toInt();
      var rng = ColituLmRng(seed);
      for (final want in v['next'] as List) {
        expect(rng.next(), (want as num).toInt(), reason: 'seed $seed next');
      }
      rng = ColituLmRng(seed);
      for (final want in v['floats'] as List) {
        expect(rng.nextFloat(), (want as num).toDouble(), reason: 'seed $seed float');
      }
    }
  });

  test('Beta samples', () {
    var count = 0;
    for (final v in (doc['beta_samples'] as List).cast<Map>()) {
      final rng = ColituLmRng((v['seed'] as num).toInt());
      final alpha = (v['alpha'] as num).toDouble();
      final beta = (v['beta'] as num).toDouble();
      for (final want in v['expected'] as List) {
        expect(
          ColituLm.sampleBeta(rng, alpha, beta),
          closeTo((want as num).toDouble(), tolerance),
        );
        count++;
      }
    }
    expect(count, 16);
  });

  test('all 29 decision cases', () {
    final cases = (doc['cases'] as List).cast<Map>();
    expect(cases, hasLength(29));
    final failures = <String>[];
    for (final c in cases) {
      final name = c['name'] as String;
      final got = ColituLm.decide(ColituLmInput.fromJson(c['input'] as Map));
      _compare(name, got, c['expected'] as Map, tolerance, failures);
    }
    expect(failures, isEmpty, reason: failures.join(' || '));
  });

  test('switch off or no model: AC 3 rules', () {
    const candidate = ColituLmCandidate(nodeId: '00000000-0000-4000-8000-0000000000de', protocol: 'trojan');
    const model = ColituLmModel(version: 1);
    expect(
      ColituLm.decide(const ColituLmInput(model: model, candidates: [candidate])).engine,
      ColituLm.engineAc3,
    );
    expect(
      ColituLm.decide(const ColituLmInput(engineEnabled: true, candidates: [candidate])).engine,
      ColituLm.engineAc3,
    );
    expect(
      ColituLm.decide(
        const ColituLmInput(model: ColituLmModel(version: 2), engineEnabled: true, candidates: [candidate]),
      ).engine,
      ColituLm.engineAc3,
    );
  });

  test('the model survives a JSON round trip', () {
    final input = (doc['cases'] as List).cast<Map>().first['input'] as Map;
    final model = ColituLmModel.fromJson(input['model'])!;
    final again = ColituLmModel.fromJson(jsonDecode(jsonEncode(model.toJson())))!;
    expect(again.version, model.version);
    expect(again.weights.hint, model.weights.hint);
    expect(again.explore, model.explore);
    expect(jsonEncode(again.priors), jsonEncode(model.priors));
  });
}

void _compare(
  String name,
  ColituLmDecision got,
  Map want,
  double tolerance,
  List<String> failures,
) {
  void check(bool ok, String what) {
    if (!ok) failures.add('$name: $what');
  }

  bool near(double a, Object? b) => (a - (b as num).toDouble()).abs() <= tolerance;

  check(got.engine == want['engine'], 'engine ${got.engine}');
  check(got.stale == want['stale'], 'stale');
  check(got.explored == want['explored'], 'explored');
  check(got.whitelistNone == want['whitelist_none'], 'whitelist_none');
  final wantRanking = want['ranking'] is List
      ? [for (final i in want['ranking'] as List) (i as num).toInt()]
      : <int>[];
  check(
    got.ranking.join(',') == wantRanking.join(','),
    'ranking ${got.ranking} want $wantRanking',
  );
  final wantChoice = want['choice'] is num ? (want['choice'] as num).toInt() : null;
  check(got.choice == wantChoice, 'choice ${got.choice} want $wantChoice');
  final wantCandidates = want['candidates'] is List ? (want['candidates'] as List).cast<Map>() : <Map>[];
  check(
    got.candidates.length == wantCandidates.length,
    'candidates ${got.candidates.length} want ${wantCandidates.length}',
  );
  for (var i = 0; i < got.candidates.length && i < wantCandidates.length; i++) {
    final g = got.candidates[i];
    final w = wantCandidates[i];
    final features = g.features.toJson();
    (w['features'] as Map).forEach((key, value) {
      check(near(features[key]!, value), '[$i] feature $key ${features[key]} want $value');
    });
    check(near(g.alpha, w['alpha']), '[$i] alpha ${g.alpha}');
    check(near(g.beta, w['beta']), '[$i] beta ${g.beta}');
    check(near(g.logOdds, w['log_odds']), '[$i] log_odds ${g.logOdds}');
    check(near(g.score, w['score']), '[$i] score ${g.score}');
    check(g.eligible == w['eligible'], '[$i] eligible');
    check(g.tier == (w['tier'] as num).toInt(), '[$i] tier');
    final theta = w['theta'];
    check(
      theta == null ? g.theta == null : g.theta != null && near(g.theta!, theta),
      '[$i] theta ${g.theta} want $theta',
    );
  }
}
