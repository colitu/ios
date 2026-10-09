import 'dart:convert';
import 'dart:io';

import 'package:colitu_vpn/colitu/api/endpoint_list.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _mirrors = ['https://mirror.example.test'];

String _fixture(String name) =>
    File('test/fixtures/$name.signed.json').readAsStringSync();

void main() {
  group('signed list verification', () {
    test('valid fixture is accepted', () {
      final list = EndpointListVerifier.verify(_fixture('valid'));
      expect(list, isNotNull);
      expect(list!.version, 1000);
      expect(list.api, [
        'https://api.colitu.com/api/v1',
        'https://mirror.example.test/capi/v1',
      ]);
      expect(list.lists, hasLength(2));
    });

    test('tampered payload is rejected', () {
      expect(EndpointListVerifier.verify(_fixture('tampered')), isNull);
    });

    test('wrong key id is rejected', () {
      expect(EndpointListVerifier.verify(_fixture('wrong-key-id')), isNull);
    });

    test('garbage is rejected without throwing', () {
      expect(EndpointListVerifier.verify('not json'), isNull);
      expect(EndpointListVerifier.verify('{}'), isNull);
      final broken = jsonDecode(_fixture('valid')) as Map<String, dynamic>;
      broken['signature'] = 'AAAA';
      expect(EndpointListVerifier.verify(jsonEncode(broken)), isNull);
    });

    test('an equal or older version is rejected, a newer one accepted', () {
      final raw = _fixture('valid');
      expect(
        EndpointListVerifier.verify(raw, currentVersion: 1000),
        isNull,
      );
      expect(
        EndpointListVerifier.verify(raw, currentVersion: 1001),
        isNull,
      );
      expect(
        EndpointListVerifier.verify(raw, currentVersion: 999),
        isNotNull,
      );
    });

    test('the manager keeps the stored list and refuses a repeat', () async {
      final storage = MemoryEndpointStorage();
      final manager = EndpointManager(storage: storage, enabled: true, mirrors: _mirrors);
      expect(await manager.accept(_fixture('valid')), isTrue);
      expect(storage.version, 1000);
      expect(await manager.accept(_fixture('valid')), isFalse);
      expect(await manager.accept(_fixture('tampered')), isFalse);
      expect(storage.list, _fixture('valid'));
    });

    test('a stored list is verified again when loaded', () async {
      final storage = MemoryEndpointStorage()
        ..list = _fixture('tampered')
        ..version = 1;
      final manager = EndpointManager(storage: storage, enabled: true, mirrors: _mirrors);
      expect(await manager.bases(), [
        'https://api.colitu.com/api/v1',
        'https://mirror.example.test/capi/v1',
      ]);
      expect(manager.acceptedList, isNull);
    });
  });

  test('mirror origins come from the build and extend the built-in lists', () {
    final mirrors = AppEnvironment.parseMirrorOrigins(
      ' https://mirror.example.test/, http://plain.example.test,junk,'
      'https://other.example.test ',
    );
    expect(mirrors, [
      'https://mirror.example.test',
      'https://other.example.test',
    ]);
    expect(AppEnvironment.apiBasesFor(mirrors), [
      'https://api.colitu.com/api/v1',
      'https://mirror.example.test/capi/v1',
      'https://other.example.test/capi/v1',
    ]);
    expect(AppEnvironment.listUrlsFor(const []), [
      'https://colitu.com/downloads/endpoints.json',
    ]);
  });

  group('base order', () {
    const bases = [
      'https://a.example/v1',
      'https://b.example/v1',
      'https://c.example/v1',
    ];

    test('list order when nothing worked yet', () {
      expect(orderApiBases(bases), bases);
    });

    test('the base that last worked comes first, others keep order', () {
      expect(orderApiBases(bases, lastWorking: 'https://c.example/v1'), [
        'https://c.example/v1',
        'https://a.example/v1',
        'https://b.example/v1',
      ]);
    });

    test('duplicates collapse; an unknown last base is ignored', () {
      expect(
        orderApiBases(
          [
            'https://a.example/v1/',
            'https://a.example/v1',
            'https://b.example/v1',
          ],
          lastWorking: 'https://zzz.example/v1',
        ),
        ['https://a.example/v1', 'https://b.example/v1'],
      );
    });

    test('the manager puts the remembered base first', () async {
      final storage = MemoryEndpointStorage();
      final manager = EndpointManager(storage: storage, enabled: true, mirrors: _mirrors);
      await manager.rememberWorking('https://mirror.example.test/capi/v1');
      expect((await manager.bases()).first, 'https://mirror.example.test/capi/v1');
      expect(storage.lastWorking, 'https://mirror.example.test/capi/v1');
    });

    test('with the override set only that base is used', () async {
      final manager = EndpointManager(
        storage: MemoryEndpointStorage(),
        enabled: false, mirrors: _mirrors,
      );
      expect(await manager.bases(), hasLength(1));
    });
  });

  group('failover classification', () {
    DioException error(
      DioExceptionType type, {
      Object? inner,
      Response<dynamic>? response,
    }) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: type,
      error: inner,
      response: response,
    );

    test('network-level errors move to the next base', () {
      expect(
        shouldFailOver(error(DioExceptionType.connectionError), 'GET'),
        isTrue,
      );
      expect(
        shouldFailOver(error(DioExceptionType.connectionTimeout), 'POST'),
        isTrue,
      );
      expect(
        shouldFailOver(
          error(DioExceptionType.unknown, inner: const SocketException('x')),
          'POST',
        ),
        isTrue,
      );
      expect(
        shouldFailOver(
          error(DioExceptionType.unknown, inner: HandshakeException('tls')),
          'GET',
        ),
        isTrue,
      );
    });

    test('other unknown errors and cancellation do not', () {
      expect(
        shouldFailOver(
          error(DioExceptionType.unknown, inner: StateError('x')),
          'GET',
        ),
        isFalse,
      );
      expect(shouldFailOver(error(DioExceptionType.cancel), 'GET'), isFalse);
    });

    test('an HTTP response never fails over', () {
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 500,
      );
      expect(
        shouldFailOver(
          error(DioExceptionType.badResponse, response: response),
          'GET',
        ),
        isFalse,
      );
    });

    test('read/send timeouts fail over for GET only', () {
      expect(
        shouldFailOver(error(DioExceptionType.receiveTimeout), 'GET'),
        isTrue,
      );
      expect(
        shouldFailOver(error(DioExceptionType.receiveTimeout), 'POST'),
        isFalse,
      );
      expect(
        shouldFailOver(error(DioExceptionType.sendTimeout), 'PUT'),
        isFalse,
      );
    });
  });

  group('interceptor', () {
    Dio build(
      EndpointManager manager,
      Future<ResponseBody> Function(RequestOptions) handler,
    ) {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'https://placeholder.example',
          validateStatus: (s) => s != null,
        ),
      );
      dio.httpClientAdapter = _Adapter(handler);
      dio.interceptors.add(ApiFailoverInterceptor(dio, manager));
      return dio;
    }

    ResponseBody ok() => ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

    test('connection failure moves on and remembers the base', () async {
      final storage = MemoryEndpointStorage();
      final manager = EndpointManager(storage: storage, enabled: true, mirrors: _mirrors);
      final hosts = <String>[];
      final dio = build(manager, (o) async {
        hosts.add(o.uri.host);
        if (o.uri.host == 'api.colitu.com') {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
          );
        }
        return ok();
      });
      final response = await dio.get<Object?>('/me');
      expect(response.statusCode, 200);
      expect(hosts, ['api.colitu.com', 'mirror.example.test']);
      expect(storage.lastWorking, 'https://mirror.example.test/capi/v1');
      hosts.clear();
      await dio.get<Object?>('/me');
      expect(hosts, ['mirror.example.test']);
    });

    test('HTTP 500 is returned as is, no second base', () async {
      final manager = EndpointManager(
        storage: MemoryEndpointStorage(),
        enabled: true, mirrors: _mirrors,
      );
      final hosts = <String>[];
      final dio = build(manager, (o) async {
        hosts.add(o.uri.host);
        return ResponseBody.fromString('{}', 500);
      });
      final response = await dio.get<Object?>('/me');
      expect(response.statusCode, 500);
      expect(hosts, ['api.colitu.com']);
    });

    test('every base is tried once, then the error is returned', () async {
      final manager = EndpointManager(
        storage: MemoryEndpointStorage(),
        enabled: true, mirrors: _mirrors,
      );
      final hosts = <String>[];
      final dio = build(manager, (o) async {
        hosts.add(o.uri.host);
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionTimeout,
        );
      });
      await expectLater(
        dio.post<Object?>('/auth/login', data: {'a': 1}),
        throwsA(isA<DioException>()),
      );
      expect(hosts, ['api.colitu.com', 'mirror.example.test']);
    });

    test('a POST read timeout is not repeated on another base', () async {
      final manager = EndpointManager(
        storage: MemoryEndpointStorage(),
        enabled: true, mirrors: _mirrors,
      );
      final hosts = <String>[];
      final dio = build(manager, (o) async {
        hosts.add(o.uri.host);
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      });
      await expectLater(
        dio.post<Object?>('/x', data: {}),
        throwsA(isA<DioException>()),
      );
      expect(hosts, ['api.colitu.com']);
    });

    test('disabled by the override: the base is left alone', () async {
      final manager = EndpointManager(
        storage: MemoryEndpointStorage(),
        enabled: false, mirrors: _mirrors,
      );
      final hosts = <String>[];
      final dio = build(manager, (o) async {
        hosts.add(o.uri.host);
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionError,
        );
      });
      await expectLater(dio.get<Object?>('/me'), throwsA(isA<DioException>()));
      expect(hosts, ['placeholder.example']);
    });
  });

  test('refresh stores the first accepted file, at most every 6 hours', () async {
    final storage = MemoryEndpointStorage();
    var now = DateTime.utc(2026, 10, 9);
    final calls = <String>[];
    final fetcher = Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null,
      ),
    );
    fetcher.httpClientAdapter = _Adapter((o) async {
      calls.add(o.uri.toString());
      if (o.uri.host == 'colitu.com') {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionError,
        );
      }
      return ResponseBody.fromString(_fixture('valid'), 200);
    });
    final manager = EndpointManager(
      storage: storage,
      enabled: true, mirrors: _mirrors,
      fetcher: fetcher,
      clock: () => now,
    );
    await manager.refreshIfDue();
    expect(calls, [
      'https://colitu.com/downloads/endpoints.json',
      'https://mirror.example.test/downloads/endpoints.json',
    ]);
    expect(storage.version, 1000);

    calls.clear();
    now = now.add(const Duration(hours: 5));
    await manager.refreshIfDue();
    expect(calls, isEmpty);
    now = now.add(const Duration(hours: 2));
    await manager.refreshIfDue();
    expect(calls, isNotEmpty);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this._handler);
  final Future<ResponseBody> Function(RequestOptions) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) => _handler(options);
}
