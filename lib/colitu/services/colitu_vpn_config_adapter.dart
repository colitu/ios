import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/core/db/database/database.dart';
import 'package:colitu_vpn/core/db/database/enum.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/core/network/client.dart';
import 'package:colitu_vpn/core/pigeon/host_api.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:colitu_vpn/service/share/xray_share_reader.dart';
import 'package:colitu_vpn/service/ping/state.dart';
import 'package:colitu_vpn/service/xray/json_writer.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_db.dart';
import 'package:colitu_vpn/service/xray/outbound/state_ping.dart';
import 'package:colitu_vpn/service/xray/outbound/state_reader.dart';
import 'package:colitu_vpn/service/xray/outbound/state_validator.dart';
import 'package:colitu_vpn/service/xray/outbound/state_writer.dart';
import 'package:colitu_vpn/service/xray/setting/inbounds_state.dart';
import 'package:colitu_vpn/service/xray/standard.dart';

typedef _Candidate = ({VPNOutboundCandidate candidate, OutboundState state});

class ColituVPNConfigAdapter {
  /// Transport of the candidate chosen by the last [prepareConnectionConfig]
  /// call, so a failed traffic check can exclude it on the next attempt.
  String? lastChosenProtocol;

  /// Probe latency of the chosen transport in milliseconds, or -1 when the
  /// probe did not answer and the transport was started on rank alone.
  int lastChosenLatencyMs = -1;

  /// Anonymous token of the network the attempt is made on (network
  /// hints); sent with the protocol observations, never anything else.
  String? networkToken;

  /// Transports in the order they are preferred. Hysteria2 (QUIC) keeps
  /// working on lossy links where the TCP transports stall, so it goes first,
  /// like on Windows.
  static const transportRank = <String, int>{
    'hysteria2': 0,
    'vless-reality': 1,
    'vless-xhttp': 2,
    'trojan': 3,
    'shadowsocks': 4,
  };

  /// Order key of a transport: the preferred (last-good, proven) one
  /// first, then [transportRank]; stall marks ignored for this round
  /// ([soft], see `colituStallMarks`) after the unmarked ones; stalled and
  /// hinted-blocked ones ([excluded]) after every other.
  static int transportRankFor(
    String protocol, {
    Set<String> excluded = const {},
    Set<String> soft = const {},
    String? prefer,
  }) =>
      (protocol == prefer ? -1 : (transportRank[protocol] ?? 5)) +
      (excluded.contains(protocol)
          ? 20
          : soft.contains(protocol)
          ? 10
          : 0);

  static const _probeTimeout = Duration(milliseconds: 3000);
  static const _quicProbeTimeout = Duration(milliseconds: 3600);

  Future<int> prepareConnectionConfig(
    VPNConfig config, {
    VPNServer? server,
    Set<String> excludeProtocols = const {},
    Set<String> skipProtocols = const {},
    String? preferProtocol,
    Set<String> softExcludeProtocols = const {},
    List<String>? startOrder,
  }) async {
    final rows = <CoreConfigCompanion>[];
    final name = _displayName(server, config);
    lastChosenProtocol = null;
    lastChosenLatencyMs = -1;

    if (_hasValue(config.rawConfig)) {
      rows.addAll(await _rowsFromText(config.rawConfig!, name));
    }

    if (rows.isEmpty && config.outboundCandidates.isNotEmpty) {
      rows.add(
        await _bestCandidateRow(
          _withoutSkipped(config.outboundCandidates, skipProtocols),
          name,
          config.serverId,
          excludeProtocols,
          preferProtocol,
          softExcludeProtocols,
          startOrder,
        ),
      );
    } else if (rows.isEmpty && config.outboundConfig != null) {
      rows.add(_rowFromOutboundMap(config.outboundConfig!, name));
    }

    if (rows.isEmpty && _hasValue(config.subscriptionUrl)) {
      final text = await NetClient().getText(config.subscriptionUrl!);
      if (_hasValue(text)) {
        rows.addAll(await _rowsFromText(text!, name));
      }
    }

    if (rows.isEmpty) {
      throw const APIException(
        APIErrorCode.configMissing,
        'VPN configuration is missing or unsupported',
      );
    }

    await _deletePreviousRuntimeConfig();
    var row = _selectBestRow(rows, server).copyWith(
      name: Value<String>(name),
      subId: const Value<int>(DBConstants.defaultId),
    );
    final id = await AppDatabase().coreConfigDao.insertRow(row);
    await PreferencesKey().saveColituRuntimeConfigId(id);
    await PreferencesKey().saveLastConfigId(id);
    return id;
  }

  /// Leaves out the transports this connect already tried. If that would
  /// leave nothing, every candidate stays (the caller then stops anyway).
  static List<VPNOutboundCandidate> _withoutSkipped(
    List<VPNOutboundCandidate> candidates,
    Set<String> skip,
  ) {
    if (skip.isEmpty) return candidates;
    final left = candidates
        .where((c) => !skip.contains(c.protocolType))
        .toList();
    return left.isEmpty ? candidates : left;
  }

  Future<void> clearRuntimeConfig() async {
    await _deletePreviousRuntimeConfig();
    await PreferencesKey().clearColituSelectedServerId();
    await PreferencesKey().clearColituWarmSpareChoice();
  }

  /// The core outbound for a panel outbound (the warm spare); throws
  /// [APIException] when the bundled core cannot run it.
  /// `POST /client/protocol-observations` body; `network_token` only when
  /// known for the network the attempt was made on.
  static Map<String, dynamic> protocolObservationBody(
    String serverId,
    List<Map<String, dynamic>> observations,
    String? token,
  ) => {
    'node_id': serverId,
    'observations': observations,
    if (token != null && token.isNotEmpty) 'network_token': token,
  };

  OutboundState outboundStateFor(
    Map<String, dynamic> outboundJson,
    String name,
  ) => _stateFromOutboundMap(outboundJson, name);

  Future<List<CoreConfigCompanion>> _rowsFromText(
    String text,
    String name,
  ) async {
    final trimmed = text.trim();
    if (trimmed.startsWith('{')) {
      final json = JsonTool.decoder.convert(trimmed) as Map<String, dynamic>;
      if (json['outbounds'] is List) {
        return [_rowFromRawJson(json, name)];
      }
      if (json['protocol'] != null) {
        return [_rowFromOutboundMap(json, name)];
      }
    }
    return XrayShareReader().parseShareText(trimmed);
  }

  CoreConfigCompanion _rowFromOutboundMap(
    Map<String, dynamic> outboundJson,
    String name,
  ) {
    return _stateFromOutboundMap(outboundJson, name).outboundCompanion;
  }

  OutboundState _stateFromOutboundMap(
    Map<String, dynamic> outboundJson,
    String name,
  ) {
    final outbound = XrayOutbound.fromJson(outboundJson);
    final state = OutboundState();
    if (!state.readFromOutbound(outbound)) {
      throw const APIException(
        APIErrorCode.configMissing,
        'Outbound configuration is not compatible with the VPN engine',
      );
    }
    state.name = name;
    state.removeWhitespace();
    return state;
  }

  /// Probes every transport the panel offers at the same time and takes the
  /// best-ranked one that answers (Hysteria2 first, then the TCP transports).
  /// The whole selection takes one probe window instead of one per transport.
  Future<CoreConfigCompanion> _bestCandidateRow(
    List<VPNOutboundCandidate> candidates,
    String name,
    String serverId,
    Set<String> excludeProtocols, [
    String? preferProtocol,
    Set<String> softExcludeProtocols = const {},
    List<String>? startOrder,
  ]) async {
    final states = <_Candidate>[];
    final observations = <String, Map<String, dynamic>>{};
    for (final candidate in candidates) {
      try {
        states.add((
          candidate: candidate,
          state: _stateFromOutboundMap(candidate.outboundConfig, name),
        ));
      } catch (_) {
        // An optional transport may not be supported by the bundled core.
        // Keep the remaining candidates usable instead of rejecting the
        // complete server configuration.
        observations[candidate.protocolType] = {
          'protocol': candidate.protocolType,
          'reachable': false,
        };
      }
    }
    if (states.isEmpty) {
      throw const APIException(
        APIErrorCode.configMissing,
        'VPN configuration is missing or unsupported',
      );
    }
    // Transports that stalled on this network go last; if every transport is
    // excluded the ranking still applies and the exclusion is ignored. The
    // transport that last carried traffic to this server on this network
    // (Adaptive Connect memory) goes first.
    int rankOf(String protocol) => transportRankFor(
      protocol,
      excluded: excludeProtocols,
      soft: softExcludeProtocols,
      prefer: preferProtocol,
    );
    bool fresh(_Candidate entry) =>
        !excludeProtocols.contains(entry.candidate.protocolType);
    states.sort(
      (left, right) => rankOf(
        left.candidate.protocolType,
      ).compareTo(rankOf(right.candidate.protocolType)),
    );

    // Hinted start (Adaptive Connect 3.0): the order was decided from the
    // network hints; the first transport that is on offer starts without a
    // probe round.
    if (startOrder != null) {
      int position(_Candidate entry) {
        final at = startOrder.indexOf(entry.candidate.protocolType);
        return at < 0 ? startOrder.length : at;
      }

      final ordered = [...states]
        ..sort((a, b) => position(a).compareTo(position(b)));
      final selected = ordered.first;
      lastChosenProtocol = selected.candidate.protocolType;
      lastChosenLatencyMs = -1;
      debugPrint('Hinted start, no probe: -> $lastChosenProtocol');
      return selected.state.outboundCompanion.copyWith(
        delay: const Value<int>(PingDelayConstants.unknown),
      );
    }

    // Probe answers by protocol; a missing entry did not answer.
    final delays = <String, int>{};
    _Candidate? bestReachable(bool Function(_Candidate) allowed) {
      _Candidate? best;
      for (final entry in states) {
        final delay = delays[entry.candidate.protocolType];
        if (delay == null || !allowed(entry)) continue;
        final bestDelay = best == null
            ? null
            : delays[best.candidate.protocolType]!;
        if (best == null ||
            rankOf(entry.candidate.protocolType) <
                rankOf(best.candidate.protocolType) ||
            (rankOf(entry.candidate.protocolType) ==
                    rankOf(best.candidate.protocolType) &&
                delay < bestDelay!)) {
          best = entry;
        }
      }
      return best;
    }

    // A newly issued credential reaches the node asynchronously; one short
    // second pass over the best two silent transports covers that window.
    for (var pass = 0; pass < 2; pass++) {
      final round = pass == 0
          ? states
          : states
                .where(
                  (s) =>
                      fresh(s) &&
                      !delays.containsKey(s.candidate.protocolType),
                )
                .take(2)
                .toList();
      if (round.isEmpty) break;
      final results = await _probeAll(round);
      for (var i = 0; i < round.length; i++) {
        final entry = round[i];
        final delay = results[i];
        final reachable = delay >= 0 && delay < PingDelayConstants.unknown;
        observations[entry.candidate.protocolType] = {
          'protocol': entry.candidate.protocolType,
          'reachable': reachable,
          if (reachable) 'latency_ms': delay,
        };
        if (reachable) delays[entry.candidate.protocolType] = delay;
      }
      if (bestReachable(fresh) != null) break;
      if (pass == 0) {
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }
    // Order: a transport that answered, then one that did not answer the
    // probe (Hysteria's QUIC probe can miss on a busy mobile link while the
    // tunnel itself works), then the ones that stalled here a little earlier.
    final chosen = bestReachable(fresh);
    final silentFresh = states.where(fresh).firstOrNull;
    final fallback = bestReachable((_) => true);
    final chosenDelay = chosen != null
        ? delays[chosen.candidate.protocolType]!
        : silentFresh == null && fallback != null
        ? delays[fallback.candidate.protocolType]!
        : PingDelayConstants.unknown;
    if (serverId.isNotEmpty) {
      unawaited(
        _reportProtocolObservations(
          serverId,
          observations.values.toList(),
          networkToken,
        ),
      );
    }
    // Nothing fresh answered the probe: start the best-ranked fresh transport
    // anyway and let the post-connect traffic check decide.
    final selected = chosen ?? silentFresh ?? fallback ?? states.first;
    lastChosenProtocol = selected.candidate.protocolType;
    lastChosenLatencyMs = chosenDelay == PingDelayConstants.unknown
        ? -1
        : chosenDelay;
    debugPrint(
      'Transport probe: ${observations.values.map((o) => '${o['protocol']}=${o['reachable'] == true ? '${o['latency_ms']}ms' : 'x'}').join(' ')} -> $lastChosenProtocol',
    );
    return selected.state.outboundCompanion.copyWith(
      delay: Value<int>(chosenDelay),
    );
  }

  /// Runs one probe per candidate in parallel. Ports are allocated up front
  /// so two probes never race for the same local port.
  Future<List<int>> _probeAll(List<_Candidate> round) async {
    if (round.isEmpty) return const [];
    List<int> ports;
    try {
      ports = await AppHostApi().getFreePorts(round.length);
    } catch (_) {
      ports = const [];
    }
    if (ports.length < round.length) {
      // Fall back to sequential probing with per-call allocation.
      final delays = <int>[];
      for (final entry in round) {
        delays.add(await _probe(entry, null));
      }
      return delays;
    }
    return Future.wait([
      for (var i = 0; i < round.length; i++) _probe(round[i], '${ports[i]}'),
    ]);
  }

  Future<int> _probe(_Candidate entry, String? port) async {
    final quic = entry.candidate.protocolType == 'hysteria2';
    final timeout = quic ? _quicProbeTimeout : _probeTimeout;
    final ping = PingState()
      ..timeout = (timeout.inMilliseconds / 1000).ceilToDouble()
      ..concurrency = 1;
    try {
      final Future<int> probe;
      if (port == null) {
        probe = entry.state.ping(ping);
      } else {
        final inbound = InboundPingState()..port = port;
        final xrayJson = XrayJsonStandard.standard;
        xrayJson.outbounds = [entry.state.xrayJson];
        xrayJson.inbounds = [inbound.xrayJson];
        probe = xrayJson.ping(ping, port);
      }
      return await probe.timeout(
        timeout + const Duration(milliseconds: 700),
        onTimeout: () => PingDelayConstants.timeout,
      );
    } catch (_) {
      return PingDelayConstants.timeout;
    }
  }

  Future<void> _reportProtocolObservations(
    String serverId,
    List<Map<String, dynamic>> observations,
    String? token,
  ) async {
    try {
      await APIClient().post<void>(
        APIEndpoint.protocolObservations,
        (_) {},
        data: protocolObservationBody(serverId, observations, token),
      );
    } catch (_) {
      // Telemetry must never prevent a VPN connection.
    }
  }

  CoreConfigCompanion _rowFromRawJson(Map<String, dynamic> json, String name) {
    final text = JsonTool.encoderForDb.convert(json);
    final base64Data = base64Encode(utf8.encode(text));
    return CoreConfigCompanion.insert(
      name: name,
      type: CoreConfigType.raw.name,
      tags: 'colitu,api',
      data: Value<String>(base64Data),
      delay: PingDelayConstants.unknown,
      subId: DBConstants.defaultId,
    );
  }

  Future<void> _deletePreviousRuntimeConfig() async {
    final previousId = await PreferencesKey().readColituRuntimeConfigId();
    if (previousId == DBConstants.defaultId) {
      return;
    }
    final db = AppDatabase();
    final previous = await db.coreConfigDao.searchRow(previousId);
    if (previous != null) {
      await db.coreConfigDao.deleteRow(previous);
    }
    await PreferencesKey().clearColituRuntimeConfigId();
  }

  String _displayName(VPNServer? server, VPNConfig config) {
    if (server != null) {
      return server.displayTitle;
    }
    return config.serverId.isEmpty ? 'Colitu VPN' : 'Colitu ${config.serverId}';
  }

  bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

  CoreConfigCompanion _selectBestRow(
    List<CoreConfigCompanion> rows,
    VPNServer? server,
  ) {
    if (rows.length <= 1 || server == null) {
      return rows.first;
    }
    var best = rows.first;
    var bestScore = -1;
    for (final row in rows) {
      final score = _serverRowScore(server, _rowName(row));
      if (score > bestScore) {
        best = row;
        bestScore = score;
      }
    }
    if (bestScore > 0) {
      return best;
    }
    throw APIException(
      APIErrorCode.configMissing,
      'Configuration for ${server.displayCountry} was not found.',
    );
  }

  int _serverRowScore(VPNServer server, String rowName) {
    final haystack = _matchText(rowName);
    final candidates = <({String? value, int weight})>[
      (value: server.name, weight: 100),
      (value: server.displayName, weight: 100),
      (value: server.displayCountry, weight: 80),
      (value: server.country, weight: 80),
      (value: server.city, weight: 50),
      (value: server.countryCode, weight: 20),
    ];
    var score = 0;
    for (final candidate in candidates) {
      final needle = _matchText(candidate.value);
      if (needle.length >= 2 && haystack.contains(needle)) {
        score += candidate.weight;
      }
    }
    for (final token in _matchText(server.name).split(RegExp(r'\s+'))) {
      if (token.length >= 3 && haystack.contains(token)) {
        score += 15;
      }
    }
    final tag = RegExp(r'\[([^\]]+)\]').firstMatch(server.name)?.group(1);
    if (tag != null && haystack.contains(_matchText(tag))) {
      score += 25;
    }
    return score;
  }

  String _rowName(CoreConfigCompanion row) {
    return row.name.present ? row.name.value : '';
  }

  String _matchText(String? value) {
    return (value ?? '')
        .toLowerCase()
        .replaceAll('ı', 'i')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ş', 's')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }
}

/// Colitu's own name of a panel transport for the screens ("Fast" for
/// Hysteria2 and so on): the technical protocol names stay out of the UI.
String colituTransportName(String? protocol) {
  if (protocol == null || protocol.isEmpty) return '';
  final known = ColituVPNConfigAdapter.transportRank.containsKey(protocol);
  return ColituLoc.I[known ? 'transport.$protocol' : 'transport.other'];
}
