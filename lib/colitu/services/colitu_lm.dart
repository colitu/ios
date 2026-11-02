import 'dart:math' as math;

/// Adaptive Connect 4 decision model ("Colitu LM"): an exact port of the
/// panel's reference (colitu-panel internal/acmodel, docs/adaptive-connect-4.md
/// "Colitu LM reference"; the Windows port is ColituLm.cs). Every app repeats
/// the same arithmetic and must reproduce docs/ac-model-vectors.json to 1e-9,
/// so nothing here may be "improved": only +, -, *, /, ln, exp2, sqrt and cos,
/// in the reference's order. Pure logic, no I/O.
abstract final class ColituLm {
  /// The model file's `version`; any other version keeps the AC 3 rules.
  static const formatVersion = 1;

  static const defaultExplore = 0.05;
  static const defaultHalflifeH = 72.0;
  static const defaultLatencyCapMs = 1000.0;

  /// A model fetched longer ago than this is "stale" in the decision (the
  /// reference value of the shared vectors). The app refetches sooner, see
  /// [refreshAfterH].
  static const staleAfterH = 6.0;

  /// The app refetches the model this often (offline the last one stays in
  /// use).
  static const refreshAfterH = 1.0;

  /// Priors key of server-level evidence (probes without a protocol,
  /// server-hint votes).
  static const anyProtocol = '*';

  static const engineAc3 = 'ac3';
  static const engineAc4 = 'ac4';

  /// The weight of an outcome [ageH] hours old: 2^(−ageH / halflifeH).
  static double decay(double ageH, double halflifeH) {
    if (halflifeH <= 0) return 1;
    if (ageH < 0) ageH = 0;
    return math.pow(2.0, -ageH / halflifeH).toDouble();
  }

  static double clamp01(double value) =>
      value < 0 ? 0 : (value > 1 ? 1 : value);

  static double _b01(bool value) => value ? 1 : 0;

  /// low 0, medium 0.5, high 1, unknown 0.
  static double loadFeature(String? load) => switch (load) {
    'medium' => 0.5,
    'high' => 1,
    _ => 0,
  };

  /// 1 − ms / cap, clamped to 0..1; unknown is 0.
  static double latencyFeature(double? ms, double capMs) {
    if (ms == null || ms < 0) return 0;
    if (capMs <= 0) capMs = defaultLatencyCapMs;
    return clamp01(1 - ms / capMs);
  }

  /// The panel prior: the protocol's own entry, else the server-level "*",
  /// else Beta(1, 1).
  static (double, double) priorFor(
    ColituLmModel? model,
    String? country,
    String? nodeId,
    String? protocol,
  ) {
    final nodes = model?.priors[(country ?? '').toUpperCase()];
    final protocols = nodes?[(nodeId ?? '').toLowerCase()];
    if (protocols != null) {
      bool usable(List<double>? pair) =>
          pair != null && pair.length >= 2 && pair[0] > 0 && pair[1] > 0;
      final own = protocols[protocol ?? ''];
      if (usable(own)) return (own![0], own[1]);
      final any = protocols[anyProtocol];
      if (usable(any)) return (any![0], any[1]);
    }
    return (1, 1);
  }

  /// The protocol fit for the network type, 0.5 when unknown.
  static double fit(ColituLmModel? model, String? networkType, String? protocol) {
    final value = model?.protocolFit[networkType ?? '']?[protocol ?? ''];
    return value == null ? 0.5 : clamp01(value);
  }

  /// Enters in one country and exits in another (a bridge RU → abroad).
  static bool isBridge(ColituLmCandidate candidate) {
    final entry = (candidate.entryCountry ?? '').toUpperCase();
    final exit = (candidate.exitCountry ?? '').toUpperCase();
    return entry.isNotEmpty && exit.isNotEmpty && entry != exit;
  }

  /// Traffic leaves in Russia: never chosen automatically outside whitelist
  /// mode (the 2026-10-10 rule).
  static bool exitsInRussia(ColituLmCandidate candidate) =>
      (candidate.exitCountry ?? '').toUpperCase() == 'RU';

  static String candidateKey(ColituLmCandidate candidate) =>
      '${candidate.nodeId.toLowerCase()}\u0000${candidate.protocol}';

  /// Scores the candidates and picks one (see the reference for every rule).
  static ColituLmDecision decide(ColituLmInput input) {
    final model = input.model;
    if (!input.engineEnabled || model == null || model.version != formatVersion) {
      return ColituLmDecision(engine: engineAc3);
    }
    final candidates = input.candidates;
    var halflife = model.halflifeH;
    if (halflife <= 0) halflife = defaultHalflifeH;
    final scoredList = <ColituLmScored>[];

    // Own feature: this device's decayed successes and failures with the
    // server on this network, over all its protocols.
    final ownOk = <String, double>{};
    final ownFail = <String, double>{};
    for (final candidate in candidates) {
      final node = candidate.nodeId.toLowerCase();
      for (final outcome in candidate.history) {
        final target = outcome.ok ? ownOk : ownFail;
        target[node] = (target[node] ?? 0) + decay(outcome.ageH, halflife);
      }
    }

    var whitelistNone = false;
    var whitelistAny = false;
    if (input.whitelistMode) {
      whitelistAny = candidates.any((c) => c.whitelistOk);
      whitelistNone = !whitelistAny;
    }
    final useWhitelist = input.whitelistMode && whitelistAny;

    final w = model.weights;
    for (final candidate in candidates) {
      final node = candidate.nodeId.toLowerCase();
      final (priorAlpha, priorBeta) = priorFor(
        model,
        input.country,
        candidate.nodeId,
        candidate.protocol,
      );
      final ok = ownOk[node] ?? 0;
      final fail = ownFail[node] ?? 0;
      final f = ColituLmFeatures(
        latency: latencyFeature(candidate.latencyMs, model.latencyCapMs),
        own: (ok + 1) / (ok + fail + 2),
        prior: priorAlpha / (priorAlpha + priorBeta),
        hint: _b01(candidate.hintBlocked),
        recommended: _b01(candidate.recommended),
        load: loadFeature(candidate.load),
        protocolFit: fit(model, input.networkType, candidate.protocol),
        whitelist: _b01(input.whitelistMode && candidate.whitelistOk),
      );
      var alpha = priorAlpha;
      var beta = priorBeta;
      for (final outcome in candidate.history) {
        if (outcome.ok) {
          alpha += decay(outcome.ageH, halflife);
        } else {
          beta += decay(outcome.ageH, halflife);
        }
      }
      final logOdds = math.log(alpha) - math.log(beta);
      final score =
          w.latency * f.latency +
          w.own * f.own +
          w.prior * f.prior +
          w.hint * f.hint +
          w.recommended * f.recommended +
          w.load * f.load +
          w.protocolFit * f.protocolFit +
          w.whitelist * f.whitelist +
          logOdds;
      final scored = ColituLmScored(
        features: f,
        alpha: alpha,
        beta: beta,
        logOdds: logOdds,
        score: score,
      );
      if (useWhitelist) {
        scored.eligible = candidate.whitelistOk;
        scored.tier = isBridge(candidate) ? 0 : 1;
      } else {
        scored.eligible = !exitsInRussia(candidate);
      }
      scoredList.add(scored);
    }

    int compare(int a, int b) {
      final x = scoredList[a];
      final y = scoredList[b];
      if (x.tier != y.tier) return x.tier.compareTo(y.tier);
      if (x.score != y.score) return y.score.compareTo(x.score);
      final byKey = candidateKey(candidates[a]).compareTo(candidateKey(candidates[b]));
      // Dart's sort is not stable: the index keeps it so (sort.SliceStable).
      return byKey != 0 ? byKey : a.compareTo(b);
    }

    final ranking = [
      for (var i = 0; i < candidates.length; i++)
        if (scoredList[i].eligible) i,
    ]..sort(compare);
    final decision = ColituLmDecision(
      engine: engineAc4,
      stale: input.modelAgeH > staleAfterH,
      whitelistNone: whitelistNone,
      candidates: scoredList,
      ranking: ranking,
    );
    if (ranking.isEmpty) return decision;
    var choice = ranking[0];

    // Exploration: one uniform draw decides; when it explores, every
    // candidate of the best tier gets a Thompson sample in key order and the
    // highest sample wins.
    final rng = ColituLmRng(input.seed);
    if (rng.nextFloat() < model.explore) {
      decision.explored = true;
      final top = scoredList[choice].tier;
      final order = {for (var i = 0; i < ranking.length; i++) ranking[i]: i};
      final pool = ranking.where((i) => scoredList[i].tier == top).toList()
        ..sort((a, b) {
          final byKey = candidateKey(candidates[a]).compareTo(candidateKey(candidates[b]));
          return byKey != 0 ? byKey : order[a]!.compareTo(order[b]!);
        });
      var best = -1.0;
      for (final i in pool) {
        final theta = sampleBeta(rng, scoredList[i].alpha, scoredList[i].beta);
        scoredList[i].theta = theta;
        if (theta > best) {
          best = theta;
          choice = i;
        }
      }
    }
    decision.choice = choice;
    return decision;
  }

  /// Thompson sample of Beta(α, β) by its normal approximation, clamped to
  /// 0..1 (always exactly two draws, so the draw sequence is the same on
  /// every platform).
  static double sampleBeta(ColituLmRng rng, double alpha, double beta) {
    final u1 = 1 - rng.nextFloat();
    final u2 = rng.nextFloat();
    final z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
    final n = alpha + beta;
    final mean = alpha / n;
    final sd = math.sqrt(alpha * beta / (n * n * (n + 1)));
    return clamp01(mean + sd * z);
  }

  /// A random seed for production decisions (the vectors fix theirs).
  static int randomSeed() => math.Random.secure().nextInt(1 << 32);
}

/// xorshift32 (shifts 13, 17, 5); seed 0 becomes 0x9E3779B9; the first 8
/// outputs are discarded. Dart ints are 64-bit: every left shift is masked
/// back to 32 unsigned bits.
class ColituLmRng {
  ColituLmRng(int seed) : _state = seed & _mask {
    if (_state == 0) _state = _zeroSeed;
    for (var i = 0; i < _warmup; i++) {
      next();
    }
  }

  static const _mask = 0xFFFFFFFF;
  static const _zeroSeed = 0x9E3779B9;
  static const _warmup = 8;
  int _state;

  int next() {
    var x = _state;
    x ^= (x << 13) & _mask;
    x ^= x >> 17;
    x ^= (x << 5) & _mask;
    _state = x;
    return x;
  }

  /// Top 24 bits / 2^24: [0, 1), exact in a double.
  double nextFloat() => (next() >> 8) / 16777216.0;
}

double _num(Object? value, double fallback) =>
    value is num ? value.toDouble() : fallback;

class ColituLmWeights {
  const ColituLmWeights({
    this.latency = 1.0,
    this.own = 1.5,
    this.prior = 1.0,
    this.hint = -2.0,
    this.recommended = 0.25,
    this.load = -0.5,
    this.protocolFit = 0.5,
    this.whitelist = 1.0,
  });

  final double latency;
  final double own;
  final double prior;
  final double hint;
  final double recommended;
  final double load;
  final double protocolFit;
  final double whitelist;

  factory ColituLmWeights.fromJson(Object? json) {
    if (json is! Map) return const ColituLmWeights();
    const d = ColituLmWeights();
    return ColituLmWeights(
      latency: _num(json['latency'], d.latency),
      own: _num(json['own'], d.own),
      prior: _num(json['prior'], d.prior),
      hint: _num(json['hint'], d.hint),
      recommended: _num(json['recommended'], d.recommended),
      load: _num(json['load'], d.load),
      protocolFit: _num(json['protocol_fit'], d.protocolFit),
      whitelist: _num(json['whitelist'], d.whitelist),
    );
  }

  Map<String, dynamic> toJson() => {
    'latency': latency,
    'own': own,
    'prior': prior,
    'hint': hint,
    'recommended': recommended,
    'load': load,
    'protocol_fit': protocolFit,
    'whitelist': whitelist,
  };
}

/// Body of `GET /api/v1/client/ac-model`.
class ColituLmModel {
  const ColituLmModel({
    required this.version,
    this.generatedAt,
    this.country,
    this.weights = const ColituLmWeights(),
    this.priors = const {},
    this.protocolFit = const {},
    this.explore = ColituLm.defaultExplore,
    this.halflifeH = ColituLm.defaultHalflifeH,
    this.latencyCapMs = ColituLm.defaultLatencyCapMs,
    this.city,
    this.priorScope = const {},
  });

  final int version;
  final String? generatedAt;

  /// Country whose priors the model holds ("" when unknown: no priors).
  final String? country;
  final ColituLmWeights weights;

  /// country → node id → protocol (or "*") → [α, β].
  final Map<String, Map<String, Map<String, List<double>>>> priors;

  /// network type → protocol → 0..1.
  final Map<String, Map<String, double>> protocolFit;
  final double explore;
  final double halflifeH;
  final double latencyCapMs;

  /// The caller's city whose priors are mixed in (k-anonymous); null when
  /// none.
  final String? city;

  /// country → node id → where that server's priors come from: scope
  /// "city" (with the city) or "country". Informational: for the journal
  /// and the support report only; the arithmetic never reads it.
  final Map<String, Map<String, ({String scope, String? city})>> priorScope;

  /// "city Moscow; RU 1 city (Moscow), 1 country", empty when the model has
  /// neither.
  String get priorScopeSummary {
    final parts = <String>[
      if (city != null) 'city $city',
      for (final country in priorScope.keys.toList()..sort())
        () {
          final nodes = priorScope[country]!.values;
          final cities = {
            for (final n in nodes)
              if (n.scope == 'city' && n.city != null) n.city!,
          }.toList()..sort();
          final cityCount = nodes.where((n) => n.scope == 'city').length;
          final countryCount = nodes.length - cityCount;
          return '$country $cityCount city${cities.isEmpty ? '' : ' (${cities.join(', ')})'}, $countryCount country';
        }(),
    ];
    return parts.join('; ');
  }

  static Map<String, Map<String, ({String scope, String? city})>> _parseScope(
    Object? raw,
  ) {
    final result = <String, Map<String, ({String scope, String? city})>>{};
    if (raw is! Map) return result;
    raw.forEach((country, nodes) {
      if (country is! String || nodes is! Map) return;
      final byNode = <String, ({String scope, String? city})>{};
      nodes.forEach((node, value) {
        if (node is! String || value is! Map) return;
        final scope = value['scope'];
        if (scope != 'city' && scope != 'country') return;
        final city = value['city'];
        byNode[node] = (
          scope: scope as String,
          city: scope == 'city' && city is String && city.trim().isNotEmpty
              ? city.trim()
              : null,
        );
      });
      if (byNode.isNotEmpty) result[country] = byNode;
    });
    return result;
  }

  /// Null when [json] is not an object or has no numeric version.
  static ColituLmModel? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    if (version is! num) return null;
    final priors = <String, Map<String, Map<String, List<double>>>>{};
    final rawPriors = json['priors'];
    if (rawPriors is Map) {
      rawPriors.forEach((country, nodes) {
        if (country is! String || nodes is! Map) return;
        final byNode = <String, Map<String, List<double>>>{};
        nodes.forEach((node, protocols) {
          if (node is! String || protocols is! Map) return;
          final byProtocol = <String, List<double>>{};
          protocols.forEach((protocol, pair) {
            if (protocol is! String || pair is! List) return;
            byProtocol[protocol] = [
              for (final value in pair)
                if (value is num) value.toDouble(),
            ];
          });
          byNode[node] = byProtocol;
        });
        priors[country] = byNode;
      });
    }
    final fit = <String, Map<String, double>>{};
    final rawFit = json['protocol_fit'];
    if (rawFit is Map) {
      rawFit.forEach((type, protocols) {
        if (type is! String || protocols is! Map) return;
        fit[type] = {
          for (final entry in protocols.entries)
            if (entry.key is String && entry.value is num)
              entry.key as String: (entry.value as num).toDouble(),
        };
      });
    }
    final generated = json['generated_at'];
    final country = json['country'];
    final city = json['city'];
    return ColituLmModel(
      version: version.toInt(),
      generatedAt: generated is String ? generated : null,
      country: country is String ? country : null,
      weights: ColituLmWeights.fromJson(json['weights']),
      priors: priors,
      protocolFit: fit,
      explore: _num(json['explore'], ColituLm.defaultExplore),
      halflifeH: _num(json['halflife_h'], ColituLm.defaultHalflifeH),
      latencyCapMs: _num(json['latency_cap_ms'], ColituLm.defaultLatencyCapMs),
      city: city is String && city.trim().isNotEmpty ? city.trim() : null,
      priorScope: _parseScope(json['prior_scope']),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'generated_at': ?generatedAt,
    'country': ?country,
    'weights': weights.toJson(),
    'city': ?city,
    'priors': priors,
    if (priorScope.isNotEmpty)
      'prior_scope': {
        for (final country in priorScope.entries)
          country.key: {
            for (final node in country.value.entries)
              node.key: {'scope': node.value.scope, 'city': ?node.value.city},
          },
      },
    'protocol_fit': protocolFit,
    'explore': explore,
    'halflife_h': halflifeH,
    'latency_cap_ms': latencyCapMs,
  };
}

/// One past outcome of this device on this network with a server and
/// protocol, [ageH] hours ago.
class ColituLmOutcome {
  const ColituLmOutcome({required this.ageH, required this.ok});

  final double ageH;
  final bool ok;

  static ColituLmOutcome? fromJson(Object? json) => json is Map
      ? ColituLmOutcome(ageH: _num(json['age_h'], 0), ok: json['ok'] == true)
      : null;
}

/// One (server or route, protocol) automatic mode may use.
class ColituLmCandidate {
  const ColituLmCandidate({
    required this.nodeId,
    required this.protocol,
    this.entryCountry,
    this.exitCountry,
    this.whitelistOk = false,
    this.recommended = false,
    this.hintBlocked = false,
    this.load,
    this.latencyMs,
    this.history = const [],
  });

  final String nodeId;
  final String protocol;
  final String? entryCountry;
  final String? exitCountry;
  final bool whitelistOk;
  final bool recommended;
  final bool hintBlocked;
  final String? load;

  /// Null: unknown.
  final double? latencyMs;
  final List<ColituLmOutcome> history;

  factory ColituLmCandidate.fromJson(Map json) {
    String? text(String key) => json[key] is String ? json[key] as String : null;
    final latency = json['latency_ms'];
    final history = json['history'];
    return ColituLmCandidate(
      nodeId: text('node_id') ?? '',
      protocol: text('protocol') ?? '',
      entryCountry: text('entry_country'),
      exitCountry: text('exit_country'),
      whitelistOk: json['whitelist_ok'] == true,
      recommended: json['recommended'] == true,
      hintBlocked: json['hint_blocked'] == true,
      load: text('load'),
      latencyMs: latency is num ? latency.toDouble() : null,
      history: history is List
          ? [
              for (final item in history)
                ?ColituLmOutcome.fromJson(item),
            ]
          : const [],
    );
  }

  Map<String, dynamic> toJournal({required int historyCount}) => {
    'node_id': nodeId,
    'protocol': protocol,
    'entry': entryCountry,
    'exit': exitCountry,
    'latency_ms': latencyMs,
    'history': historyCount,
  };
}

/// Everything one decision needs.
class ColituLmInput {
  const ColituLmInput({
    this.model,
    this.modelAgeH = 0,
    this.engineEnabled = false,
    this.country,
    this.networkType,
    this.whitelistMode = false,
    this.seed = 0,
    this.candidates = const [],
  });

  final ColituLmModel? model;
  final double modelAgeH;
  final bool engineEnabled;
  final String? country;
  final String? networkType;
  final bool whitelistMode;

  /// uint32.
  final int seed;
  final List<ColituLmCandidate> candidates;

  factory ColituLmInput.fromJson(Map json) {
    final candidates = json['candidates'];
    final seed = json['seed'];
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return ColituLmInput(
      model: ColituLmModel.fromJson(json['model']),
      modelAgeH: _num(json['model_age_h'], 0),
      engineEnabled: json['engine_enabled'] == true,
      country: text('country'),
      networkType: text('network_type'),
      whitelistMode: json['whitelist_mode'] == true,
      seed: seed is num ? seed.toInt() : 0,
      candidates: candidates is List
          ? [
              for (final item in candidates)
                if (item is Map) ColituLmCandidate.fromJson(item),
            ]
          : const [],
    );
  }
}

class ColituLmFeatures {
  const ColituLmFeatures({
    required this.latency,
    required this.own,
    required this.prior,
    required this.hint,
    required this.recommended,
    required this.load,
    required this.protocolFit,
    required this.whitelist,
  });

  final double latency;
  final double own;
  final double prior;
  final double hint;
  final double recommended;
  final double load;
  final double protocolFit;
  final double whitelist;

  Map<String, double> toJson() => {
    'latency': latency,
    'own': own,
    'prior': prior,
    'hint': hint,
    'recommended': recommended,
    'load': load,
    'protocol_fit': protocolFit,
    'whitelist': whitelist,
  };
}

class ColituLmScored {
  ColituLmScored({
    required this.features,
    required this.alpha,
    required this.beta,
    required this.logOdds,
    required this.score,
  });

  final ColituLmFeatures features;
  final double alpha;
  final double beta;
  final double logOdds;
  final double score;
  bool eligible = false;

  /// In whitelist mode bridges are 0 and other whitelist servers 1;
  /// otherwise always 0.
  int tier = 0;

  /// The Thompson sample, only when the decision explored.
  double? theta;

  Map<String, dynamic> toJson() => {
    'features': features.toJson(),
    'alpha': alpha,
    'beta': beta,
    'log_odds': logOdds,
    'score': score,
    'eligible': eligible,
    'tier': tier,
    'theta': ?theta,
  };
}

/// The model's answer. Engine "ac3": use the Adaptive Connect 3 rules (the
/// other fields are empty).
class ColituLmDecision {
  ColituLmDecision({
    required this.engine,
    this.stale = false,
    this.whitelistNone = false,
    this.candidates = const [],
    this.ranking = const [],
  });

  final String engine;
  final bool stale;
  bool explored = false;
  final bool whitelistNone;
  final List<ColituLmScored> candidates;

  /// Indexes of the eligible candidates, best first.
  final List<int> ranking;

  /// Index of the candidate to connect to first; null when none is eligible.
  int? choice;
}
