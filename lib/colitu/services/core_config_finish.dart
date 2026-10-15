/// Last touches on a core configuration before it is written.
abstract final class ColituCoreConfig {
  /// Xray 26.10 refuses to start ("duplicate ruleTag") when two routing
  /// rules share a `ruleTag`; the app's own writers give several rules the
  /// same tag (split tunneling writes up to three `colituSplit` rules, a
  /// stored routing setting may repeat "custom"). The written copy gets
  /// unique tags: the first keeps its tag, the next ones get "#2", "#3"…
  /// The tags only name rules (for logs and the routing API); matching does
  /// not depend on them, and the app finds its rules by tag before this
  /// step, in its own state.
  static void uniqueRuleTags(Map<String, dynamic> config) {
    final routing = config['routing'];
    final rules = routing is Map ? routing['rules'] : null;
    if (rules is! List) return;
    final used = <String>{
      for (final rule in rules)
        if (rule is Map && rule['ruleTag'] is String) rule['ruleTag'] as String,
    };
    final seen = <String>{};
    for (final rule in rules) {
      if (rule is! Map) continue;
      final tag = rule['ruleTag'];
      if (tag is! String || tag.isEmpty) continue;
      if (seen.add(tag)) continue;
      var n = 2;
      while (used.contains('$tag#$n')) {
        n++;
      }
      final unique = '$tag#$n';
      rule['ruleTag'] = unique;
      used.add(unique);
      seen.add(unique);
    }
  }
}
