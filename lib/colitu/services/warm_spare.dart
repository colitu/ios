import 'dart:async';
import 'dart:math';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';

/// Warm spare (core-level hot standby): a second, already configured path in
/// the running Xray core. A balancer sends traffic to the primary outbound
/// while the burst observatory sees it alive and to the spare once it is
/// not, so the switch happens inside the core within seconds, also while
/// the app is in the background. The app-level stall watch and the Adaptive
/// Connect fallback still act when both paths are dead.
///
/// Checked against the bundled Xray 26.3.27 (`infra/conf`): routing
/// `balancers[].{tag, selector, fallbackTag, strategy}`, rule `balancerTag`,
/// top-level `burstObservatory.{subjectSelector, pingConfig}` with
/// `pingConfig.{destination, connectivity, interval, sampling, timeout}`
/// (durations as strings such as "10s").
class ColituWarmSpare {
  ColituWarmSpare._();

  static const primaryTag = 'proxy';

  /// Not "proxy-spare": Xray matches balancer and observatory selectors by
  /// prefix, so `selector: ["proxy"]` would also pick a "proxy-spare"
  /// outbound and spread traffic over both at random.
  static const spareTag = 'warm-spare';
  static const balancerTag = 'proxy-auto';

  /// Probe through the primary every [probeInterval] (one sample: a failed
  /// probe marks it dead, the next good one brings it back). Plain HTTP
  /// keeps a probe near 1 KB inside the tunnel; a failed probe is only
  /// counted when [connectivityUrl] answers directly (the device is online).
  static const probeUrl = 'http://www.gstatic.com/generate_204';
  static const connectivityUrl =
      'http://connectivitycheck.gstatic.com/generate_204';
  static const probeInterval = Duration(seconds: 10);
  static const probeTimeout = Duration(seconds: 3);
  static const probeSampling = 1;

  static bool isUdp(String protocol) => protocol == 'hysteria2';

  /// `sockopt.tcpUserTimeout` of TCP outbounds while a spare is attached.
  static const tcpUserTimeoutMs = 10000;

  /// Whether a tunnel gets a spare at all: the setting is on, the primary
  /// transport is known and it is not a multihop route.
  static bool wanted({
    required bool enabled,
    required bool multihop,
    required String? primaryProtocol,
  }) => enabled && !multihop && (primaryProtocol ?? '').isNotEmpty;

  static const _tcpOrder = [
    'vless-reality',
    'vless-xhttp',
    'trojan',
    'shadowsocks',
  ];

  /// Spare transport for a primary on [primaryProtocol] among [offered]:
  /// the other family when possible (UDP primary: Reality, XHTTP, Trojan,
  /// Shadowsocks; TCP primary: Hysteria2, then another TCP transport).
  /// Stalled transports are never picked. On the same server the primary's
  /// own transport is never the spare; on another server it comes last.
  /// [vlessOnly] while a rotating exit is on.
  static String? pickTransport({
    required String primaryProtocol,
    required Iterable<String> offered,
    Set<String> stalled = const {},
    Set<String> hinted = const {},
    required bool sameServer,
    bool vlessOnly = false,
  }) {
    // A protocol the network hints call blocked only when nothing else is
    // offered.
    if (hinted.isNotEmpty) {
      final unhinted = pickTransport(
        primaryProtocol: primaryProtocol,
        offered: offered.where((p) => !hinted.contains(p)),
        stalled: stalled,
        sameServer: sameServer,
        vlessOnly: vlessOnly,
      );
      if (unhinted != null) return unhinted;
    }
    final available = offered.toSet();
    final order = [
      if (!isUdp(primaryProtocol)) 'hysteria2',
      for (final p in _tcpOrder)
        if (p != primaryProtocol) p,
      if (!sameServer) primaryProtocol,
    ];
    for (final protocol in order) {
      if (!available.contains(protocol) || stalled.contains(protocol)) continue;
      if (vlessOnly && !protocol.startsWith('vless')) continue;
      return protocol;
    }
    return null;
  }

  /// Spare transport by the Adaptive Connect 2.0 rule.
  ///
  /// Another server (automatic mode): a transport proven on this network
  /// in the last 24 h on any server, the primary's own first (same family
  /// allowed); only when nothing offered is proven, the other family
  /// (UDP <-> TCP), then the rest. Same server (a server the user picked):
  /// never the primary's own transport, the other family first, Shadowsocks
  /// last. Stalled transports and [avoid] never; hinted-blocked ones only
  /// when nothing else is offered. Null when there is no spare.
  static ColituSpareDecision? decide({
    required bool sameServer,
    required String primaryProtocol,
    required Iterable<String> offered,
    Set<String> proven = const {},
    Set<String> stalled = const {},
    Set<String> hinted = const {},
    Set<String> avoid = const {},
    bool vlessOnly = false,
  }) {
    final usable = [
      for (final p in offered.toSet())
        if (!stalled.contains(p) &&
            !avoid.contains(p) &&
            (!vlessOnly || p.startsWith('vless')) &&
            !(sameServer && p == primaryProtocol))
          p,
    ];
    ColituSpareDecision? pick(List<String> pool, {required bool fallback}) {
      if (pool.isEmpty) return null;
      int order(String p) => _orderFor(p, primaryProtocol, sameServer: sameServer);
      if (!sameServer) {
        final provenHere = pool.where(proven.contains).toList()
          ..sort((a, b) => order(a).compareTo(order(b)));
        // The primary's own transport leads when it is proven.
        provenHere.sort((a, b) {
          if (a == primaryProtocol) return -1;
          if (b == primaryProtocol) return 1;
          return order(a).compareTo(order(b));
        });
        if (provenHere.isNotEmpty) {
          return ColituSpareDecision(
            provenHere.first,
            fallback ? 'hinted-fallback' : 'proven',
          );
        }
      }
      final sorted = [...pool]..sort((a, b) => order(a).compareTo(order(b)));
      final choice = sorted.first;
      final reason = fallback
          ? 'hinted-fallback'
          : isUdp(choice) != isUdp(primaryProtocol)
          ? 'other-family'
          : 'same-transport';
      return ColituSpareDecision(choice, reason);
    }

    return pick(
          usable.where((p) => !hinted.contains(p)).toList(),
          fallback: false,
        ) ??
        pick(usable, fallback: true);
  }

  /// Other family first (UDP <-> TCP), then the remaining TCP transports in
  /// the usual order with Shadowsocks last; on another server the primary's
  /// own transport comes right after the other family.
  static int _orderFor(
    String protocol,
    String primaryProtocol, {
    required bool sameServer,
  }) {
    final otherFamily = isUdp(protocol) != isUdp(primaryProtocol);
    final base = otherFamily ? 0 : (protocol == primaryProtocol ? 10 : 20);
    final rank = protocol == 'hysteria2'
        ? 0
        : (_tcpOrder.indexOf(protocol) + 1).clamp(1, _tcpOrder.length + 1);
    return base + rank;
  }

  /// Spare server in automatic mode: the best-ranked other server that is
  /// not penalized on this network (and not in [avoid]). [ranked] is the
  /// Adaptive Connect order.
  static VPNServer? pickServer(
    List<VPNServer> ranked,
    VPNServer primary, {
    required ColituAdaptiveMemory memory,
    required String network,
    required DateTime now,
    Set<String> avoid = const {},
  }) {
    for (final server in ranked) {
      if (server.isMultihop || !server.isSelectable) continue;
      if (server.selectionKey == primary.selectionKey) continue;
      if (avoid.contains(server.selectionKey)) continue;
      if (memory.isPenalized(network, server.selectionKey, now)) continue;
      return server;
    }
    return null;
  }

  /// Turns a generated core config that carries both the [primaryTag] and
  /// the [spareTag] outbound into the warm-spare form: balancer, burst
  /// observatory, and every rule that pointed at the primary now on the
  /// balancer, plus a last catch-all rule (the primary is the first, i.e.
  /// default, outbound). [verify] becomes a loopback inbound whose traffic
  /// the first rule sends to the primary itself, never the balancer: the
  /// connect-time traffic check runs through it, so a dead primary cannot
  /// pass the check over the spare (the core's first probe marks it dead
  /// within seconds of the start). Returns false (config untouched)
  /// without both outbounds.
  ///
  /// `sockopt.dialerProxy` cannot name a balancer in Xray: the DNS
  /// outbound's dialer stays on the primary (it rejects non-IP queries, so
  /// nothing uses it).
  static bool applyTo(
    Map<String, dynamic> config, {
    required ColituVerifyProxy verify,
    required ColituVerifyProxy verifySpare,
  }) {
    final outbounds = config['outbounds'];
    if (outbounds is! List) return false;
    final tags = {
      for (final outbound in outbounds)
        if (outbound is Map) outbound['tag'],
    };
    if (!tags.contains(primaryTag) || !tags.contains(spareTag)) return false;

    final routing = config['routing'] is Map<String, dynamic>
        ? config['routing'] as Map<String, dynamic>
        : (config['routing'] = <String, dynamic>{});
    final rules = routing['rules'] is List
        ? routing['rules'] as List
        : (routing['rules'] = <dynamic>[]);
    for (final rule in rules) {
      if (rule is Map && rule['outboundTag'] == primaryTag) {
        rule.remove('outboundTag');
        rule['balancerTag'] = balancerTag;
      }
    }
    // The DNS module's own queries get an explicit rule to the balancer at
    // the top (right after the two check rules).
    final dnsTag = config['dns'] is Map ? (config['dns'] as Map)['tag'] : null;
    if (dnsTag is String && dnsTag.isNotEmpty) {
      final dnsRules = [
        for (final rule in rules)
          if (rule is Map &&
              rule['inboundTag'] is List &&
              (rule['inboundTag'] as List).contains(dnsTag))
            rule,
      ];
      rules.removeWhere(dnsRules.contains);
      rules.insertAll(
        0,
        dnsRules.isEmpty
            ? [
                <String, dynamic>{
                  'inboundTag': [dnsTag],
                  'balancerTag': balancerTag,
                },
              ]
            : dnsRules,
      );
    }
    // Check inbounds: the primary alone, the spare alone; first rules, never
    // the balancer.
    rules.insertAll(0, [
      <String, dynamic>{
        'inboundTag': [ColituVerifyProxy.tag],
        'outboundTag': primaryTag,
      },
      <String, dynamic>{
        'inboundTag': [ColituVerifyProxy.spareTag],
        'outboundTag': spareTag,
      },
    ]);
    // A dead TCP path is noticed by the kernel within 10 s (Xray applies
    // tcpUserTimeout on Linux only; on iOS it is a no-op kept for parity).
    for (final outbound in outbounds) {
      if (outbound is! Map) continue;
      final tag = outbound['tag'];
      if (tag != primaryTag && tag != spareTag) continue;
      final stream = outbound['streamSettings'] is Map
          ? outbound['streamSettings'] as Map
          : (outbound['streamSettings'] = <String, dynamic>{}) as Map;
      final quic = outbound['protocol'] == 'hysteria' ||
          stream['network'] == 'hysteria';
      if (quic) continue;
      final sockopt = stream['sockopt'] is Map
          ? stream['sockopt'] as Map
          : (stream['sockopt'] = <String, dynamic>{}) as Map;
      sockopt['tcpUserTimeout'] = tcpUserTimeoutMs;
    }
    rules.add(<String, dynamic>{
      'network': 'tcp,udp',
      'balancerTag': balancerTag,
    });
    final inbounds = config['inbounds'] is List
        ? config['inbounds'] as List
        : (config['inbounds'] = <dynamic>[]);
    inbounds.add(verify.inboundTagged(ColituVerifyProxy.tag));
    inbounds.add(verifySpare.inboundTagged(ColituVerifyProxy.spareTag));
    final balancers = routing['balancers'] is List
        ? routing['balancers'] as List
        : (routing['balancers'] = <dynamic>[]);
    balancers.add(<String, dynamic>{
      'tag': balancerTag,
      'selector': [primaryTag],
      'fallbackTag': spareTag,
      'strategy': {'type': 'random'},
    });
    // Only the primary is probed: the balancer never asks about the spare
    // (it is the fallback whatever its state), and probing it would double
    // the traffic and keep its connection (Hysteria2: a QUIC session)
    // open in the extension's small memory budget.
    config['burstObservatory'] = <String, dynamic>{
      'subjectSelector': [primaryTag],
      'pingConfig': {
        'destination': probeUrl,
        'connectivity': connectivityUrl,
        'interval': '${probeInterval.inSeconds}s',
        'sampling': probeSampling,
        'timeout': '${probeTimeout.inSeconds}s',
      },
    };
    return true;
  }
}

/// Checks a generated core config for references that would leave traffic
/// nowhere: a rule without a target or naming an outbound or balancer that
/// does not exist, a balancer whose selector or fallback matches no
/// outbound, a `dialerProxy` to a missing outbound, a check-inbound rule
/// that is not first or matches more than its own inbound, an observatory
/// subject that matches nothing. Empty when the config is sound.
List<String> colituConfigProblems(Map<String, dynamic> config) {
  final problems = <String>[];
  final outbounds = config['outbounds'] is List
      ? (config['outbounds'] as List).whereType<Map>().toList()
      : <Map>[];
  final outboundTags = {for (final o in outbounds) '${o['tag'] ?? ''}'};
  bool selects(String selector) =>
      outboundTags.any((tag) => tag.startsWith(selector));
  final routing = config['routing'] is Map ? config['routing'] as Map : {};
  final balancers = routing['balancers'] is List
      ? (routing['balancers'] as List).whereType<Map>().toList()
      : <Map>[];
  final balancerTags = {for (final b in balancers) '${b['tag'] ?? ''}'};
  for (final b in balancers) {
    final selector = b['selector'] is List ? b['selector'] as List : const [];
    if (selector.isEmpty || !selector.every((s) => selects('$s'))) {
      problems.add('balancer ${b['tag']} selects nothing');
    }
    final fallback = b['fallbackTag'];
    if (fallback != null && !outboundTags.contains(fallback)) {
      problems.add('balancer ${b['tag']} falls back to missing $fallback');
    }
  }
  final rules = routing['rules'] is List
      ? (routing['rules'] as List).whereType<Map>().toList()
      : <Map>[];
  for (var i = 0; i < rules.length; i++) {
    final rule = rules[i];
    final out = rule['outboundTag'];
    final balancer = rule['balancerTag'];
    if (out == null && balancer == null) {
      problems.add('rule $i has no target');
    }
    if (out != null && !outboundTags.contains(out)) {
      problems.add('rule $i -> missing outbound $out');
    }
    if (balancer != null && !balancerTags.contains(balancer)) {
      problems.add('rule $i -> missing balancer $balancer');
    }
    final inbound = rule['inboundTag'] is List ? rule['inboundTag'] as List : const [];
    for (final (tag, target) in _checkInbounds) {
      if (!inbound.contains(tag)) continue;
      final own = i < 2 &&
          inbound.length == 1 &&
          rule.length == 2 &&
          out == target;
      if (!own) problems.add('rule $i: check inbound rule is not exact');
    }
  }
  final inbounds = config['inbounds'] is List
      ? (config['inbounds'] as List).whereType<Map>().toList()
      : <Map>[];
  for (final (tag, _) in _checkInbounds) {
    final hasInbound = inbounds.any((i) => i['tag'] == tag);
    final hasRule = rules.take(2).any(
      (r) => r['inboundTag'] is List && (r['inboundTag'] as List).contains(tag),
    );
    if (hasInbound != hasRule) {
      problems.add('check inbound $tag and its rule do not match');
    }
  }
  for (final o in outbounds) {
    final stream = o['streamSettings'];
    final sockopt = stream is Map ? stream['sockopt'] : null;
    final dialer = sockopt is Map ? sockopt['dialerProxy'] : null;
    if (dialer != null && !outboundTags.contains(dialer)) {
      problems.add('outbound ${o['tag']} dials through missing $dialer');
    }
  }
  final observatory = config['burstObservatory'];
  if (observatory is Map) {
    final subjects = observatory['subjectSelector'] is List
        ? observatory['subjectSelector'] as List
        : const [];
    if (subjects.isEmpty || !subjects.every((s) => selects('$s'))) {
      problems.add('observatory observes nothing');
    }
  }
  return problems;
}

const _checkInbounds = [
  (ColituVerifyProxy.tag, ColituWarmSpare.primaryTag),
  (ColituVerifyProxy.spareTag, ColituWarmSpare.spareTag),
];

/// Loopback HTTP proxies into the core: [tag] always leaves through the
/// primary outbound, [spareTag] through the spare (random port and
/// credentials per start). The app's traffic checks use them while a warm
/// spare is configured.
class ColituVerifyProxy {
  const ColituVerifyProxy({
    required this.port,
    required this.user,
    required this.pass,
  });

  static const tag = 'colitu-verify';
  static const spareTag = 'colitu-verify-spare';
  static const host = '127.0.0.1';

  /// The primary's check proxy of the running tunnel; null without a warm
  /// spare.
  static ColituVerifyProxy? current;

  /// The spare's check proxy; null without a warm spare.
  static ColituVerifyProxy? currentSpare;

  final int port;
  final String user;
  final String pass;

  factory ColituVerifyProxy.random(int port) {
    final random = Random.secure();
    String token() => [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    return ColituVerifyProxy(port: port, user: token(), pass: token());
  }

  /// `HttpClient.findProxy` answer; Dart sends the credentials up front.
  String get directive => 'PROXY $user:$pass@$host:$port';

  Map<String, dynamic> get inbound => inboundTagged(tag);

  Map<String, dynamic> inboundTagged(String tag) => {
    'tag': tag,
    'listen': host,
    'port': port,
    'protocol': 'http',
    'settings': {
      'accounts': [
        {'user': user, 'pass': pass},
      ],
    },
  };
}

/// The spare chosen for one connect: its server and transport and the
/// panel's outbound for it, stored for the prepared primary config
/// [configId] so a restart of the same tunnel keeps it.
///
/// After a role swap (the spare passed, the primary did not) [primary]
/// replaces the prepared primary; the spare fields may then be empty (no
/// spare left).
class ColituSpareChoice {
  const ColituSpareChoice({
    required this.configId,
    required this.server,
    required this.protocol,
    required this.outbound,
    this.reason = '',
    this.primary,
  });

  final int configId;
  final String server;
  final String protocol;
  final Map<String, dynamic> outbound;

  /// proven, other-family, same-transport or hinted-fallback.
  final String reason;
  final ColituPath? primary;

  bool get hasSpare => outbound.isNotEmpty && protocol.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'config_id': configId,
    'server': server,
    'protocol': protocol,
    'outbound': outbound,
    if (reason.isNotEmpty) 'reason': reason,
    if (primary != null) 'primary': primary!.toJson(),
  };

  static ColituSpareChoice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['config_id'];
    final outbound = json['outbound'];
    if (id is! num || outbound is! Map) return null;
    return ColituSpareChoice(
      configId: id.toInt(),
      server: '${json['server'] ?? ''}',
      protocol: '${json['protocol'] ?? ''}',
      outbound: Map<String, dynamic>.from(outbound),
      reason: '${json['reason'] ?? ''}',
      primary: ColituPath.fromJson(json['primary']),
    );
  }
}

/// One path of the core: a server, a transport and its panel outbound.
class ColituPath {
  const ColituPath({
    required this.server,
    required this.protocol,
    required this.outbound,
  });

  final String server;
  final String protocol;
  final Map<String, dynamic> outbound;

  Map<String, dynamic> toJson() => {
    'server': server,
    'protocol': protocol,
    'outbound': outbound,
  };

  static ColituPath? fromJson(Object? json) {
    if (json is! Map || json['outbound'] is! Map) return null;
    return ColituPath(
      server: '${json['server'] ?? ''}',
      protocol: '${json['protocol'] ?? ''}',
      outbound: Map<String, dynamic>.from(json['outbound'] as Map),
    );
  }
}

/// A spare transport and why it was chosen.
class ColituSpareDecision {
  const ColituSpareDecision(this.protocol, this.reason);

  final String protocol;
  final String reason;
}

enum ColituRoundWinner { primary, spare, none }

/// Parallel connect round: the traffic check runs through the primary and
/// the spare at the same time. The primary passing wins at once; when only
/// the spare passed, the primary still gets [grace] before the spare wins.
/// Both failing: none. [elapsed] is the time to the decision.
Future<({ColituRoundWinner winner, Duration elapsed})> colituParallelRound({
  required Future<bool> Function() primary,
  required Future<bool> Function() spare,
  Duration grace = const Duration(milliseconds: 1500),
}) async {
  final watch = Stopwatch()..start();
  final done = Completer<ColituRoundWinner>();
  bool? primaryOk;
  bool? spareOk;
  Timer? graceTimer;
  void settle() {
    if (done.isCompleted) return;
    if (primaryOk == true) {
      done.complete(ColituRoundWinner.primary);
    } else if (spareOk == true && primaryOk == false) {
      done.complete(ColituRoundWinner.spare);
    } else if (primaryOk == false && spareOk == false) {
      done.complete(ColituRoundWinner.none);
    } else if (spareOk == true && primaryOk == null) {
      graceTimer ??= Timer(grace, () {
        if (!done.isCompleted && primaryOk != true) {
          done.complete(ColituRoundWinner.spare);
        }
      });
    }
  }

  unawaited(
    primary()
        .catchError((Object _) => false)
        .then((ok) {
          primaryOk = ok;
          settle();
        }),
  );
  unawaited(
    spare()
        .catchError((Object _) => false)
        .then((ok) {
          spareOk = ok;
          settle();
        }),
  );
  final winner = await done.future;
  graceTimer?.cancel();
  return (winner: winner, elapsed: watch.elapsed);
}
