import 'package:flutter_test/flutter_test.dart';
import 'package:colitu_vpn/colitu/services/diagnostics_request_watcher.dart';
import 'package:colitu_vpn/colitu/services/support_service.dart';

class _FakeService extends Fake implements ColituSupportService {
  DiagnosticsRequest? pending;
  var failAnswer = false;
  var fetches = 0;
  final answers = <(String, String)>[];

  @override
  Future<DiagnosticsRequest?> pendingDiagnosticsRequest() async {
    fetches++;
    return pending;
  }

  @override
  Future<void> answerDiagnosticsRequest(String requestId, String report) async {
    if (failAnswer) throw Exception('offline');
    answers.add((requestId, report));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DiagnosticsRequest.fromResponse', () {
    test('no request', () {
      expect(DiagnosticsRequest.fromResponse({'data': {'request': null}}), isNull);
      expect(DiagnosticsRequest.fromResponse(null), isNull);
      expect(DiagnosticsRequest.fromResponse({'data': {}}), isNull);
    });

    test('pending request', () {
      final request = DiagnosticsRequest.fromResponse({
        'data': {
          'request': {
            'id': 'r1',
            'status': 'pending',
            'created_at': '2026-10-15T10:00:00Z',
            'expires_at': '2026-10-16T10:00:00Z',
          },
        },
      });
      expect(request?.id, 'r1');
    });

    test('incomplete or answered requests are ignored', () {
      expect(DiagnosticsRequest.fromResponse({'data': {'request': {'status': 'pending'}}}), isNull);
      expect(
        DiagnosticsRequest.fromResponse({
          'data': {'request': {'id': 'r1', 'status': 'answered'}},
        }),
        isNull,
      );
    });
  });

  group('DiagnosticsRequestWatcher', () {
    late _FakeService service;
    late DateTime now;
    var reports = 0;

    DiagnosticsRequestWatcher build() => DiagnosticsRequestWatcher(
      api: service,
      clock: () => now,
      buildReport: () async {
        reports++;
        return 'REPORT';
      },
    );

    setUp(() {
      service = _FakeService()..pending = const DiagnosticsRequest(id: 'r1');
      now = DateTime(2026, 10, 15, 12);
      reports = 0;
    });

    test('checks at most once per 60 seconds', () async {
      final watcher = build();
      service.pending = null;
      await watcher.check();
      now = now.add(const Duration(seconds: 30));
      await watcher.check();
      expect(service.fetches, 1);
      now = now.add(const Duration(seconds: 31));
      await watcher.check();
      expect(service.fetches, 2);
      expect(reports, 0);
    });

    test('a pending request is answered silently and only once', () async {
      final watcher = build();
      await watcher.check();
      expect(service.answers, [('r1', 'REPORT')]);
      now = now.add(const Duration(minutes: 5));
      await watcher.check();
      expect(service.answers, hasLength(1));
      expect(reports, 1);
    });

    test('a failure retries after 10 minutes', () async {
      service.failAnswer = true;
      final watcher = build();
      await watcher.check();
      expect(service.answers, isEmpty);
      now = now.add(const Duration(minutes: 5));
      await watcher.check();
      expect(reports, 1);
      service.failAnswer = false;
      now = now.add(const Duration(minutes: 6));
      await watcher.check();
      expect(service.answers, [('r1', 'REPORT')]);
    });

    test('a new request after an answered one is answered', () async {
      final watcher = build();
      await watcher.check();
      service.pending = const DiagnosticsRequest(id: 'r2');
      now = now.add(const Duration(minutes: 2));
      await watcher.check();
      expect(service.answers.map((a) => a.$1), ['r1', 'r2']);
    });
  });
}
