import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_metrics.dart';
import 'package:colitu_vpn/colitu/services/colitu_survey.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/survey/survey_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryKv implements ColituKv {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('survey answer', () {
    test('parses none and the four kinds', () {
      expect(ColituSurvey.parse({'survey': null}), isNull);
      expect(ColituSurvey.parse(null), isNull);
      expect(ColituSurvey.parse({'survey': {'kind': 'poll'}}), isNull);
      expect(ColituSurvey.parse({'survey': {'kind': 'nps'}})!.kind, 'nps');
      expect(ColituSurvey.parse({'survey': {'kind': 'PMF'}})!.kind, 'pmf');
      final csat = ColituSurvey.parse({
        'survey': {'kind': 'csat', 'conversation_id': 'c-1'},
      })!;
      expect(csat.kind, 'csat');
      expect(csat.conversationId, 'c-1');
      expect(
        ColituSurvey.parse({'survey': {'kind': 'churn', 'conversation_id': ' '}})!.conversationId,
        isNull,
      );
    });

    test('request JSON per kind', () {
      expect(
        const ColituSurvey('csat', 'c-1').body(dismissed: false, score: 4, comment: '  nice  '),
        {
          'kind': 'csat',
          'platform': 'ios',
          'dismissed': false,
          'score': 4,
          'comment': 'nice',
          'conversation_id': 'c-1',
        },
      );
      expect(
        const ColituSurvey('nps').body(dismissed: false, score: 0),
        {'kind': 'nps', 'platform': 'ios', 'dismissed': false, 'score': 0},
      );
      expect(
        const ColituSurvey('pmf').body(dismissed: false, answer: 'somewhat'),
        {'kind': 'pmf', 'platform': 'ios', 'dismissed': false, 'answer': 'somewhat'},
      );
      expect(
        const ColituSurvey('churn').body(dismissed: false, reason: 'other_vpn', comment: ' '),
        {'kind': 'churn', 'platform': 'ios', 'dismissed': false, 'reason': 'other_vpn'},
      );
    });

    test('closing sends only dismissed: true', () {
      expect(
        const ColituSurvey('nps').body(dismissed: true, score: 9, comment: 'x'),
        {'kind': 'nps', 'platform': 'ios', 'dismissed': true},
      );
      expect(
        const ColituSurvey('csat', 'c-1').body(dismissed: true),
        {'kind': 'csat', 'platform': 'ios', 'dismissed': true, 'conversation_id': 'c-1'},
      );
    });

    test('a long comment is cut to 1000 characters', () {
      final body = const ColituSurvey('churn').body(
        dismissed: false,
        reason: 'price',
        comment: 'x' * 1500,
      );
      expect((body['comment'] as String).length, 1000);
    });
  });

  group('once a day', () {
    late _MemoryKv kv;
    late DateTime now;
    late int fetches;
    Object? answer;

    ColituSurveys make() => ColituSurveys(
      store: kv,
      clock: () => now,
      fetch: () async {
        fetches++;
        if (answer is Exception) throw answer! as Exception;
        return answer;
      },
    );

    setUp(() {
      kv = _MemoryKv();
      now = DateTime(2026, 10, 11, 12);
      fetches = 0;
      answer = {'survey': {'kind': 'nps'}};
    });

    test('due: first time, after 24 h, or when the clock went back', () {
      final t = DateTime(2026, 10, 11, 12);
      expect(ColituSurveys.due(null, t), isTrue);
      expect(ColituSurveys.due(t, t.add(const Duration(hours: 23))), isFalse);
      expect(ColituSurveys.due(t, t.add(const Duration(hours: 24))), isTrue);
      expect(ColituSurveys.due(t, t.subtract(const Duration(hours: 1))), isTrue);
    });

    test('one check a day; "none" counts for the day too', () async {
      final s = make();
      expect((await s.checkNow())!.kind, 'nps');
      expect(await s.checkNow(), isNull);
      expect(fetches, 1);
      now = now.add(const Duration(hours: 25));
      answer = {'survey': null};
      expect(await s.checkNow(), isNull);
      expect(fetches, 2);
      now = now.add(const Duration(hours: 1));
      expect(await s.checkNow(), isNull);
      expect(fetches, 2);
    });

    test('with "Show surveys" off nothing is fetched', () async {
      final s = make();
      expect(await s.isEnabled(), isTrue);
      await s.setEnabled(false);
      expect(await s.isEnabled(), isFalse);
      expect(await s.checkNow(), isNull);
      expect(fetches, 0);
      await s.setEnabled(true);
      expect(await s.checkNow(), isNotNull);
    });

    test('a failed fetch is not counted as the day\'s check', () async {
      answer = const APIException(APIErrorCode.networkUnavailable, 'offline');
      final s = make();
      expect(await s.checkNow(), isNull);
      answer = {'survey': {'kind': 'pmf'}};
      expect((await s.checkNow())!.kind, 'pmf');
      expect(fetches, 2);
    });

    test('submit reports whether the panel took it', () async {
      final posts = <Map<String, dynamic>>[];
      var fail = false;
      final s = ColituSurveys(
        store: kv,
        post: (path, body) async {
          expect(path, '/client/survey');
          posts.add(body);
          if (fail) throw const APIException(APIErrorCode.backendUnavailable, 'x');
        },
      );
      expect(await s.submit({'kind': 'nps'}), isTrue);
      fail = true;
      expect(await s.submit({'kind': 'nps'}), isFalse);
      expect(posts, hasLength(2));
    });
  });

  group('bottom sheet', () {
    setUp(() async {
      await ColituLoc.I.setLanguage('tr', persist: false);
    });

    Future<void> pump(
      WidgetTester tester,
      ColituSurvey survey,
      List<Map<String, dynamic>> bodies,
    ) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ColituTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showColituSurveySheet(
                    context,
                    survey,
                    surveys: ColituSurveys(
                      store: _MemoryKv(),
                      post: (path, body) async => bodies.add(body),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('NPS: pick a score and send', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      await pump(tester, const ColituSurvey('nps'), bodies);
      expect(
        find.text('Colitu\'yu bir arkadaşınıza önerme olasılığınız nedir?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('surveyScore9')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('surveySend')));
      await tester.pumpAndSettle();
      expect(bodies.single, {
        'kind': 'nps',
        'platform': 'ios',
        'dismissed': false,
        'score': 9,
      });
      expect(find.byKey(const ValueKey('surveySheet')), findsNothing);
    });

    testWidgets('churn: reason and comment', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      await pump(tester, const ColituSurvey('churn'), bodies);
      expect(find.text('Premium\'u neden yenilemediniz?'), findsOneWidget);
      expect(find.text('Bazı siteler veya uygulamalar açılmadı'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('surveyOption.blocked')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('surveyComment')).last, 'telegram');
      await tester.tap(find.byKey(const ValueKey('surveySend')));
      await tester.pumpAndSettle();
      expect(bodies.single['reason'], 'blocked');
      expect(bodies.single['comment'], 'telegram');
      expect(bodies.single['dismissed'], isFalse);
    });

    testWidgets('closing the sheet sends dismissed: true', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      await pump(tester, const ColituSurvey('pmf'), bodies);
      expect(find.text('Çok üzülürdüm'), findsOneWidget);
      expect(find.text('Biraz üzülürdüm'), findsOneWidget);
      expect(find.text('Üzülmezdim'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('surveyClose')));
      await tester.pumpAndSettle();
      expect(bodies.single, {'kind': 'pmf', 'platform': 'ios', 'dismissed': true});
    });

    testWidgets('csat shows 1 to 5 and the support question', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      await pump(tester, const ColituSurvey('csat', 'c-9'), bodies);
      expect(find.text('Destek talebiniz nasıl çözüldü?'), findsOneWidget);
      expect(find.byKey(const ValueKey('surveyScore0')), findsNothing);
      expect(find.byKey(const ValueKey('surveyScore5')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('surveyScore5')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('surveySend')));
      await tester.pumpAndSettle();
      expect(bodies.single['score'], 5);
      expect(bodies.single['conversation_id'], 'c-9');
    });
  });
}
