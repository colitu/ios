import 'package:colitu_vpn/colitu/services/notice_service.dart';
import 'package:colitu_vpn/colitu/services/vpn_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(String id, {String level = 'info', String? expires}) =>
    {
      'id': id,
      'kind': 'campaign',
      'level': level,
      'title': 'T $id',
      'body': 'B $id',
      'expires_at': ?expires,
    };

class _MemoryStore implements NoticeStore {
  List<String> dismissed = [];
  List<String> seen = [];

  @override
  Future<List<String>> readDismissed() async => dismissed;
  @override
  Future<void> saveDismissed(List<String> ids) async => dismissed = ids;
  @override
  Future<List<String>> readSeen() async => seen;
  @override
  Future<void> saveSeen(List<String> ids) async => seen = ids;
}

class _FakeApi implements ColituVPNService {
  List<ClientNotice> answer = const [];
  Object? error;
  int fetches = 0;
  final events = <String>[];

  @override
  Future<List<ClientNotice>> notices(String language) async {
    fetches++;
    if (error != null) throw error!;
    return answer;
  }

  @override
  Future<void> noticeEvent(String id, String event) async {
    events.add('$id|$event');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('parseNotices', () {
    test('reads the contract fields', () {
      final list = parseNotices({
        'notices': [
          {
            'id': 'usage_80:1790812800',
            'kind': 'usage',
            'level': 'warning',
            'title': 'Title',
            'body': 'Body',
            'button': 'Upgrade',
            'url': 'https://colitu.com/pricing',
            'push': true,
            'expires_at': '2026-11-01T00:00:00Z',
          },
        ],
      });
      expect(list, hasLength(1));
      final n = list.single;
      expect(n.id, 'usage_80:1790812800');
      expect(n.level, NoticeLevel.warning);
      expect(n.button, 'Upgrade');
      expect(n.link, Uri.parse('https://colitu.com/pricing'));
      expect(n.expiresAt, DateTime.utc(2026, 11));
    });

    test('skips broken entries and tolerates garbage', () {
      expect(parseNotices(null), isEmpty);
      expect(parseNotices({'notices': 'x'}), isEmpty);
      expect(
        parseNotices({
          'notices': [
            1,
            {'title': 'no id'},
            {'id': 'a'},
            _json('ok', level: 'unknown'),
          ],
        }).map((e) => e.id),
        ['ok'],
      );
      expect(
        parseNotices({
          'notices': [_json('ok', level: 'unknown')],
        }).single.level,
        NoticeLevel.info,
      );
    });

    test('only an https url counts as a link', () {
      final n = ClientNotice.fromJson({
        ..._json('x'),
        'url': 'javascript:alert(1)',
        'button': 'Go',
      })!;
      expect(n.link, isNull);
      expect(
        ClientNotice.fromJson({..._json('x'), 'url': 'http://a.b'})!.link,
        isNull,
      );
    });
  });

  group('pickNextNotice', () {
    final all = parseNotices({
      'notices': [_json('a'), _json('b'), _json('c')],
    });

    test('first one not dismissed', () {
      expect(pickNextNotice(all, {})?.id, 'a');
      expect(pickNextNotice(all, {'a'})?.id, 'b');
      expect(pickNextNotice(all, {'a', 'b', 'c'}), isNull);
    });

    test('skips expired ones', () {
      final list = parseNotices({
        'notices': [
          _json('old', expires: '2026-01-01T00:00:00Z'),
          _json('new', expires: '2027-01-01T00:00:00Z'),
        ],
      });
      expect(
        pickNextNotice(list, {}, now: DateTime.utc(2026, 6))?.id,
        'new',
      );
    });
  });

  test('addCappedId keeps the newest 200 without duplicates', () {
    var ids = <String>[];
    for (var i = 0; i < 250; i++) {
      ids = addCappedId(ids, 'n$i');
    }
    expect(ids, hasLength(200));
    expect(ids.first, 'n50');
    expect(ids.last, 'n249');
    expect(addCappedId(['a', 'b'], 'a'), ['b', 'a']);
  });

  group('NoticeService', () {
    test('shows, reports seen once, dismisses to the next', () async {
      final api = _FakeApi()
        ..answer = parseNotices({
          'notices': [_json('a'), _json('b')],
        });
      final store = _MemoryStore();
      final service = NoticeService(
        api: api,
        store: store,
        language: () => 'tr',
      );
      await service.refresh();
      expect(service.current?.id, 'a');
      await _settle();
      expect(api.events, ['a|seen']);
      expect(store.seen, ['a']);

      service.dismiss(service.current!);
      expect(service.current?.id, 'b');
      await _settle();
      expect(store.dismissed, ['a']);
      expect(api.events, containsAll(['a|dismissed', 'b|seen']));

      await service.refresh(force: true);
      expect(service.current?.id, 'b');
      expect(api.events.where((e) => e == 'b|seen'), hasLength(1));
    });

    test('dismissed ids survive a new service', () async {
      final api = _FakeApi()
        ..answer = parseNotices({
          'notices': [_json('a')],
        });
      final store = _MemoryStore()..dismissed = ['a'];
      final service = NoticeService(api: api, store: store);
      await service.refresh();
      expect(service.current, isNull);
    });

    test('fetches at most every 15 minutes', () async {
      var now = DateTime.utc(2026, 10, 9, 12);
      final api = _FakeApi();
      final service = NoticeService(
        api: api,
        store: _MemoryStore(),
        clock: () => now,
      );
      await service.refresh();
      await service.refresh();
      expect(api.fetches, 1);
      now = now.add(const Duration(minutes: 16));
      await service.refresh();
      expect(api.fetches, 2);
    });

    test('an error means no notice, silently', () async {
      final api = _FakeApi()..error = Exception('404');
      final service = NoticeService(api: api, store: _MemoryStore());
      await service.refresh();
      expect(service.current, isNull);
    });
  });
}
