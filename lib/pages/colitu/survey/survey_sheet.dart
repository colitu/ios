import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_survey.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// Shows [survey] as a small dismissible bottom sheet. An answer is sent as
/// given; closing it any other way (button, swipe, tap outside) sends
/// `dismissed: true`, so the panel does not ask again. Failures are ignored.
Future<void> showColituSurveySheet(
  BuildContext context,
  ColituSurvey survey, {
  ColituSurveys? surveys,
}) async {
  final service = surveys ?? ColituSurveys.instance;
  var answered = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x99000000),
    builder: (_) => ColituSurveySheet(
      survey: survey,
      onSubmit: (body) {
        answered = true;
        unawaited(service.submit(body));
      },
    ),
  );
  if (!answered) {
    unawaited(service.submit(survey.body(dismissed: true)));
  }
}

class ColituSurveySheet extends StatefulWidget {
  const ColituSurveySheet({
    super.key,
    required this.survey,
    required this.onSubmit,
  });

  final ColituSurvey survey;

  /// Called with the request body of an answer; the sheet closes itself.
  final void Function(Map<String, dynamic> body) onSubmit;

  @override
  State<ColituSurveySheet> createState() => _ColituSurveySheetState();
}

class _ColituSurveySheetState extends State<ColituSurveySheet> {
  final _comment = TextEditingController();
  int? _score;
  String? _choice;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String get _kind => widget.survey.kind;

  bool get _hasComment => _kind == 'csat' || _kind == 'churn';

  bool get _ready => switch (_kind) {
    'csat' || 'nps' => _score != null,
    _ => _choice != null,
  };

  void _send() {
    if (!_ready) return;
    widget.onSubmit(
      widget.survey.body(
        dismissed: false,
        score: (_kind == 'csat' || _kind == 'nps') ? _score : null,
        answer: _kind == 'pmf' ? _choice : null,
        reason: _kind == 'churn' ? _choice : null,
        comment: _hasComment ? _comment.text : null,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        key: const ValueKey('surveySheet'),
        decoration: const BoxDecoration(
          color: ColituColors.navy,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(ColituRadius.lg),
          ),
          border: Border(top: BorderSide(color: ColituColors.lineStrong)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          18 + MediaQuery.paddingOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      loc['survey.$_kind'],
                      key: const ValueKey('surveyTitle'),
                      style: ColituText.h2,
                    ),
                  ),
                  ColituIconButton(
                    key: const ValueKey('surveyClose'),
                    icon: CupertinoIcons.xmark,
                    size: 36,
                    tooltip: loc['survey.close'],
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _body(loc),
              if (_hasComment) ...[
                const SizedBox(height: 14),
                ColituField(
                  key: const ValueKey('surveyComment'),
                  controller: _comment,
                  label: loc['survey.comment'],
                  maxLength: ColituSurvey.maxComment,
                ),
              ],
              const SizedBox(height: 16),
              ColituButton(
                key: const ValueKey('surveySend'),
                label: loc['survey.send'],
                onPressed: _ready ? _send : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ColituLoc loc) {
    switch (_kind) {
      case 'csat':
        return _scale(loc, 1, 5, 'survey.csat.low', 'survey.csat.high');
      case 'nps':
        return _scale(loc, 0, 10, 'survey.nps.low', 'survey.nps.high');
      case 'pmf':
        return _options(loc, ColituSurvey.pmfAnswers, 'survey.pmf');
      default:
        return _options(loc, ColituSurvey.churnReasons, 'survey.churn');
    }
  }

  Widget _scale(ColituLoc loc, int from, int to, String lowKey, String highKey) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var n = from; n <= to; n++)
              _ScoreButton(
                key: ValueKey('surveyScore$n'),
                value: n,
                selected: _score == n,
                onTap: () => setState(() => _score = n),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(loc[lowKey], style: ColituText.small)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                loc[highKey],
                style: ColituText.small,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _options(ColituLoc loc, List<String> values, String prefix) {
    return Column(
      children: [
        for (final value in values) ...[
          ColituTile(
            key: ValueKey('surveyOption.$value'),
            active: _choice == value,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            onTap: () => setState(() => _choice = value),
            child: Row(
              children: [
                Expanded(child: Text(loc['$prefix.$value'], style: ColituText.label)),
                if (_choice == value)
                  const Icon(
                    CupertinoIcons.checkmark_alt,
                    size: 18,
                    color: ColituColors.lilac,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// One number of a rating scale.
class _ScoreButton extends StatelessWidget {
  const _ScoreButton({
    super.key,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$value',
      child: ColituPressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected ? ColituGradients.activeOption : null,
            color: selected ? null : ColituColors.surface2,
            borderRadius: BorderRadius.circular(ColituRadius.pill),
            border: Border.all(
              color: selected ? Colors.transparent : ColituColors.line,
            ),
          ),
          child: Text(
            '$value',
            style: ColituText.label.copyWith(
              fontSize: 15,
              color: selected ? ColituColors.onAccent : ColituColors.text,
            ),
          ),
        ),
      ),
    );
  }
}
