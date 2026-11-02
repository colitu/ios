import 'dart:convert';

/// One journal record: when, what kind, and its data (a JSON-safe snapshot
/// taken when it was added).
class ColituEngineJournalEntry {
  const ColituEngineJournalEntry(this.at, this.kind, this.data);

  final DateTime at;

  /// decision, outcome, ping_round, hidden or whitelist.
  final String kind;
  final Object? data;

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'kind': kind,
    'data': ?data,
  };
}

/// The Adaptive Connect engine journal for the support report (AC4 phase 4):
/// every automatic decision (candidates, features, scores, choice, reason),
/// connection outcomes, ping round summaries, servers hidden by the honest
/// list and whitelist checks. A ring of the last [capacity] records, in
/// memory only; it never leaves the device by itself.
class ColituEngineJournal {
  ColituEngineJournal();

  static const capacity = 300;

  static final instance = ColituEngineJournal();

  static const decision = 'decision';
  static const outcome = 'outcome';
  static const pingRound = 'ping_round';
  static const hidden = 'hidden';
  static const whitelist = 'whitelist';

  final _ring = List<ColituEngineJournalEntry?>.filled(capacity, null);
  var _next = 0;
  var _count = 0;

  void add(String kind, Object? data, {DateTime? at}) {
    Object? snapshot;
    try {
      // A JSON round trip: later changes to [data] do not change the record.
      snapshot = data == null ? null : jsonDecode(jsonEncode(data));
    } catch (e) {
      snapshot = {'error': e.runtimeType.toString()};
    }
    _ring[_next] = ColituEngineJournalEntry(at ?? DateTime.now(), kind, snapshot);
    _next = (_next + 1) % capacity;
    _count = _count + 1 > capacity ? capacity : _count + 1;
  }

  int get count => _count;

  /// The records, oldest first.
  List<ColituEngineJournalEntry> snapshot() {
    final start = (_next - _count + capacity) % capacity;
    return [for (var i = 0; i < _count; i++) _ring[(start + i) % capacity]!];
  }

  /// The journal as a JSON array (oldest first), for the support report.
  String toJson({bool indented = false}) {
    final list = [for (final entry in snapshot()) entry.toJson()];
    return indented
        ? const JsonEncoder.withIndent('  ').convert(list)
        : jsonEncode(list);
  }

  void clear() {
    _ring.fillRange(0, capacity, null);
    _next = 0;
    _count = 0;
  }
}
