// Multihop routes (double VPN) and the rotating exit IP: the panel's
// `/multihop/*` and `/me/rotation*` answers, and the rules the app applies to
// them. Mirrors the Windows `ColituRotation` helper.

/// One end of a multihop route, or the exit a rotation currently uses.
class RouteEndpoint {
  const RouteEndpoint({this.nodeId, this.name, this.country, this.city});

  final String? nodeId;
  final String? name;

  /// Upper-case ISO country code; null when the panel sent none.
  final String? country;
  final String? city;

  /// City, else node name, else country code: how the end is named in the UI.
  String get label {
    final c = city?.trim() ?? '';
    if (c.isNotEmpty) return c;
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) return n;
    return country ?? '';
  }

  /// "FI" for the home chip; the label when there is no country code.
  String get short {
    final code = country;
    if (code != null && code.length == 2) return code;
    final text = label;
    return text.isEmpty ? '?' : text;
  }

  /// An endpoint object; a bare string is read as a node name, anything else
  /// is no endpoint.
  static RouteEndpoint? tryParse(Object? value) {
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? null : RouteEndpoint(name: text);
    }
    if (value is! Map) return null;
    final code = '${value['country'] ?? ''}'.trim().toUpperCase();
    String? text(Object? v) {
      final s = v == null ? '' : '$v'.trim();
      return s.isEmpty ? null : s;
    }

    return RouteEndpoint(
      nodeId: text(value['node_id']),
      name: text(value['name']),
      country: code.length == 2 ? code : null,
      city: text(value['city']),
    );
  }
}

class RotationCountry {
  const RotationCountry({
    required this.country,
    this.inDefault = false,
    this.exits = 0,
  });

  final String country;

  /// Part of the set used when the user picks no countries (Russia is not).
  final bool inDefault;

  /// Exit nodes the panel has in this country.
  final int exits;
}

/// The account's rotating-exit-IP preference (`/me/rotation`).
class RotationPreference {
  const RotationPreference({
    this.intervalSeconds = 0,
    this.countries = const [],
    this.intervals = const [],
    this.availableCountries = const [],
    this.protocols = const [],
    this.changesExitCountry = false,
  });

  /// 0 = off.
  final int intervalSeconds;

  /// Chosen countries; empty = the default set.
  final List<String> countries;
  final List<int> intervals;
  final List<RotationCountry> availableCountries;
  final List<String> protocols;
  final bool changesExitCountry;

  bool get active => intervalSeconds > 0;

  factory RotationPreference.fromJson(Object? json) {
    if (json is! Map) return const RotationPreference();
    final interval = json['interval_seconds'];
    final seconds = interval is num ? interval.toInt() : 0;
    final available = <RotationCountry>[];
    final rawAvailable = json['available_countries'];
    if (rawAvailable is List) {
      for (final item in rawAvailable) {
        if (item is! Map) continue;
        final code = '${item['country'] ?? ''}'.trim().toUpperCase();
        if (code.isEmpty) continue;
        final exits = item['exits'];
        available.add(
          RotationCountry(
            country: code,
            inDefault: item['in_default'] == true,
            exits: exits is num ? exits.toInt() : 0,
          ),
        );
      }
    }
    final rawIntervals = json['intervals'];
    final rawProtocols = json['protocols'];
    return RotationPreference(
      intervalSeconds: ColituRotation.isValidInterval(seconds) ? seconds : 0,
      countries: ColituRotation.normalizeCountries(
        json['countries'] is List ? (json['countries'] as List).map((v) => '$v') : null,
      ),
      intervals: rawIntervals is List
          ? ([
              for (final v in rawIntervals)
                if (v is num && v > 0) v.toInt(),
            ]..sort())
          : const [],
      availableCountries: available,
      protocols: rawProtocols is List ? [for (final v in rawProtocols) '$v'] : const [],
      changesExitCountry: json['changes_exit_country'] == true,
    );
  }
}

/// Where the rotation of the connected node is (`/me/rotation/status`).
class RotationStatus {
  const RotationStatus({
    this.active = false,
    this.reason,
    this.intervalSeconds = 0,
    this.entry,
    this.currentExit,
    this.nextExit,
    this.windowStartedAt,
    this.nextChangeAt,
    this.protocols = const [],
  });

  final bool active;

  /// off, not_in_mesh or not_enough_exits while inactive.
  final String? reason;
  final int intervalSeconds;
  final RouteEndpoint? entry;
  final RouteEndpoint? currentExit;
  final RouteEndpoint? nextExit;
  final DateTime? windowStartedAt;
  final DateTime? nextChangeAt;
  final List<String> protocols;

  factory RotationStatus.fromJson(Object? json) {
    if (json is! Map) return const RotationStatus();
    final interval = json['interval_seconds'];
    final rawProtocols = json['protocols'];
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
    final reason = '${json['reason'] ?? ''}'.trim();
    return RotationStatus(
      active: json['active'] == true,
      reason: reason.isEmpty ? null : reason,
      intervalSeconds: interval is num ? interval.toInt() : 0,
      entry: RouteEndpoint.tryParse(json['entry']),
      currentExit: RouteEndpoint.tryParse(json['current_exit']),
      nextExit: RouteEndpoint.tryParse(json['next_exit']),
      windowStartedAt: date(json['window_started_at']),
      nextChangeAt: date(json['next_change_at']),
      protocols: rawProtocols is List ? [for (final v in rawProtocols) '$v'] : const [],
    );
  }
}

enum RotationValidation {
  ok,
  invalidInterval,

  /// Fewer than two of the chosen countries have exits.
  tooFewCountries,
}

/// Validation and timing rules of the rotating exit IP.
abstract final class ColituRotation {
  /// Off, 5, 10 and 30 minutes.
  static const intervalChoices = [0, 300, 600, 1800];

  /// The status is never asked for more often than this.
  static const minStatusPollSeconds = 60;

  static const _maxStatusPollSeconds = 35 * 60;

  static bool isValidInterval(int seconds) => intervalChoices.contains(seconds);

  /// Transports a multihop route or a rotation can be carried on.
  static bool isVless(String? protocol) =>
      protocol == 'vless-reality' || protocol == 'vless-xhttp';

  /// Upper-case two-letter codes, no duplicates, sorted; anything else is dropped.
  static List<String> normalizeCountries(Iterable<String>? countries) {
    final out = <String>{};
    for (final raw in countries ?? const <String>[]) {
      var code = raw.trim().toUpperCase();
      if (code == 'UK') code = 'GB';
      if (code.length == 2 && RegExp(r'^[A-Z]{2}$').hasMatch(code)) out.add(code);
    }
    return out.toList()..sort();
  }

  /// Countries with exits that the panel includes when the user picks none.
  static List<String> defaultCountries(Iterable<RotationCountry>? available) {
    return normalizeCountries(
      (available ?? const <RotationCountry>[])
          .where((item) => item.inDefault && item.exits > 0)
          .map((item) => item.country),
    );
  }

  /// What the checklist shows: the chosen countries, or the default set.
  static List<String> selectedCountries(RotationPreference preference) {
    final chosen = normalizeCountries(preference.countries);
    return chosen.isNotEmpty ? chosen : defaultCountries(preference.availableCountries);
  }

  /// The panel's rule: an interval of 0/5/10/30 minutes, and either no
  /// countries (the default set, without Russia) or at least two countries
  /// that have exits.
  static RotationValidation validate(
    int intervalSeconds,
    Iterable<String>? countries,
    Iterable<RotationCountry>? available,
  ) {
    if (!isValidInterval(intervalSeconds)) return RotationValidation.invalidInterval;
    final chosen = normalizeCountries(countries);
    if (intervalSeconds == 0 || chosen.isEmpty) return RotationValidation.ok;
    final withExits = {
      for (final item in available ?? const <RotationCountry>[])
        if (item.exits > 0) item.country.toUpperCase(),
    };
    return chosen.where(withExits.contains).length >= 2
        ? RotationValidation.ok
        : RotationValidation.tooFewCountries;
  }

  /// The list to send: empty (= default set) while the checklist still equals
  /// the default set.
  static List<String> payloadCountries(
    Iterable<String>? selected,
    Iterable<RotationCountry>? available,
  ) {
    final chosen = normalizeCountries(selected);
    final defaults = defaultCountries(available);
    final same = chosen.length == defaults.length &&
        [for (var i = 0; i < chosen.length; i++) chosen[i] == defaults[i]].every((v) => v);
    return same ? const [] : chosen;
  }

  /// When to ask the panel for the status again: at [nextChangeAt], but never
  /// sooner than [minStatusPollSeconds] from now (and not later than the
  /// longest interval).
  static Duration nextPollDelay(DateTime? nextChangeAt, DateTime now) {
    final seconds = nextChangeAt == null
        ? minStatusPollSeconds.toDouble()
        : nextChangeAt.difference(now).inMilliseconds / 1000 + 1;
    final clamped = seconds.clamp(
      minStatusPollSeconds.toDouble(),
      _maxStatusPollSeconds.toDouble(),
    );
    return Duration(milliseconds: (clamped * 1000).round());
  }

  /// "4:07" until the next change; "0:00" once it is due.
  static String formatCountdown(Duration remaining) {
    final left = remaining.isNegative ? Duration.zero : remaining;
    final seconds = left.inSeconds % 60;
    return '${left.inMinutes}:${seconds.toString().padLeft(2, '0')}';
  }
}
