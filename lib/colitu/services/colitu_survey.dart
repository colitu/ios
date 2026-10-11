import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';

/// One question from `GET /client/survey`.
class ColituSurvey {
  const ColituSurvey(this.kind, [this.conversationId]);

  static const kinds = {'csat', 'nps', 'pmf', 'churn'};
  static const pmfAnswers = ['very', 'somewhat', 'not'];
  static const churnReasons = [
    'price',
    'speed',
    'blocked',
    'not_needed',
    'other_vpn',
    'technical',
    'other',
  ];
  static const maxComment = 1000;

  final String kind;
  final String? conversationId;

  /// `{"survey": null}` or `{"survey": {"kind", "conversation_id"?}}`; null
  /// for none or an unknown kind.
  static ColituSurvey? parse(Object? root) {
    final survey = root is Map ? root['survey'] : null;
    if (survey is! Map) return null;
    final kind = survey['kind'];
    if (kind is! String) return null;
    final k = kind.toLowerCase();
    if (!kinds.contains(k)) return null;
    final conversation = survey['conversation_id'];
    return ColituSurvey(
      k,
      conversation is String && conversation.trim().isNotEmpty
          ? conversation
          : null,
    );
  }

  /// The body of `POST /client/survey`. [score] is for csat (1-5) and nps
  /// (0-10), [answer] for pmf, [reason] for churn; a blank [comment] is left
  /// out; the conversation id travels with csat only. A dismissed survey
  /// carries no answer.
  Map<String, dynamic> body({
    required bool dismissed,
    int? score,
    String? answer,
    String? reason,
    String? comment,
  }) {
    final text = comment?.trim() ?? '';
    return {
      'kind': kind,
      'platform': ColituMetricsData.platform,
      'dismissed': dismissed,
      if (!dismissed) ...{
        'score': ?score,
        'answer': ?answer,
        'reason': ?reason,
        if (text.isNotEmpty)
          'comment': text.length > maxComment ? text.substring(0, maxComment) : text,
      },
      if (kind == 'csat' && conversationId != null)
        'conversation_id': conversationId,
    };
  }
}

/// Survey settings, the once-a-day gate and the two calls. Surveys are
/// separate from the statistics setting.
class ColituSurveys {
  ColituSurveys({
    ColituKv? store,
    DateTime Function()? clock,
    Future<Object?> Function()? fetch,
    ColituPostJson? post,
  }) : _store = store ?? PrefsColituKv(),
       _clock = clock ?? DateTime.now,
       _fetch = fetch ?? _defaultFetch,
       _post = post ?? colituPostJson;

  static final ColituSurveys instance = ColituSurveys();

  static const checkInterval = Duration(hours: 24);
  static const _kEnabled = 'colituSurveysEnabled';
  static const _kLastCheck = 'colituSurveyLastCheck';

  final ColituKv _store;
  final DateTime Function() _clock;
  final Future<Object?> Function() _fetch;
  final ColituPostJson _post;

  static Future<Object?> _defaultFetch() =>
      APIClient().get<Object?>(APIEndpoint.clientSurvey, (json) => json);

  /// "Show surveys" (default on); off stops fetching.
  Future<bool> isEnabled() async {
    try {
      return (await _store.read(_kEnabled)) != '0';
    } catch (_) {
      return true;
    }
  }

  Future<void> setEnabled(bool value) =>
      _store.write(_kEnabled, value ? '1' : '0');

  /// At most one check per day (a clock set back also allows one).
  static bool due(DateTime? last, DateTime now) =>
      last == null ||
      now.isBefore(last) ||
      now.difference(last) >= checkInterval;

  /// The survey to show now, or null: surveys off, already checked today,
  /// nothing pending or any failure. A completed check (even "none") counts
  /// for the day. The caller checks that the user is signed in and not
  /// connecting.
  Future<ColituSurvey?> checkNow() async {
    try {
      if (!await isEnabled()) return null;
      final now = _clock();
      final raw = int.tryParse(await _store.read(_kLastCheck) ?? '');
      final last = raw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(raw);
      if (!due(last, now)) return null;
      final answer = await _fetch();
      await _store.write(_kLastCheck, '${now.millisecondsSinceEpoch}');
      return ColituSurvey.parse(answer);
    } catch (_) {
      return null;
    }
  }

  /// True when the panel took the answer (204). Failures are ignored by the
  /// caller.
  Future<bool> submit(Map<String, dynamic> body) async {
    try {
      await _post(APIEndpoint.clientSurvey, body);
      return true;
    } catch (_) {
      return false;
    }
  }
}
