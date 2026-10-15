import 'dart:async';
import 'dart:typed_data';

import 'package:colitu_vpn/colitu/api/body_limit.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/log_redaction.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.chunks, {this.contentLength});

  final List<int> chunks;
  final int? contentLength;
  var cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>(
      onCancel: () => cancelled = true,
    );
    () async {
      for (final size in chunks) {
        if (controller.isClosed) return;
        await Future<void>.delayed(Duration.zero);
        controller.add(Uint8List(size)..fillRange(0, size, 0x20));
      }
      await controller.close();
    }();
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        if (contentLength != null)
          Headers.contentLengthHeader: ['$contentLength'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(HttpClientAdapter inner, int limit) =>
    Dio()..httpClientAdapter = BodyLimitAdapter(inner, defaultLimit: limit);

void main() {
  group('BodyLimitAdapter', () {
    test('a body under the limit arrives whole', () async {
      final res = await _dio(_FakeAdapter([100, 100]), 1000).get<String>(
        'https://api.example.test/x',
        options: Options(responseType: ResponseType.plain),
      );
      expect(res.data!.length, 200);
    });

    test('a growing body over the limit fails and stops reading', () async {
      final inner = _FakeAdapter([600, 600, 600, 600]);
      await expectLater(
        _dio(inner, 1000).get<String>(
          'https://api.example.test/x',
          options: Options(responseType: ResponseType.plain),
        ),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<ResponseTooLargeException>(),
          ),
        ),
      );
      expect(inner.cancelled, isTrue);
    });

    test('a declared Content-Length over the limit fails at once', () async {
      await expectLater(
        _dio(_FakeAdapter([10], contentLength: 5000), 1000).get<String>(
          'https://api.example.test/x',
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('a request can raise its own limit', () async {
      final res = await _dio(_FakeAdapter([600, 600]), 1000).get<List<int>>(
        'https://api.example.test/x',
        options: Options(
          responseType: ResponseType.bytes,
          extra: {BodyLimitAdapter.extraKey: 2000},
        ),
      );
      expect(res.data!.length, 1200);
    });
  });

  group('server config', () {
    test('a raw Xray config or subscription URL is no connection payload', () {
      expect(
        VPNConfig.fromJson({
          'raw_config':
              '{"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{}}',
        }).hasConnectionPayload,
        isFalse,
      );
      expect(
        VPNConfig.fromJson({
          'subscription_url': 'https://sub.example.test/x',
        }).hasConnectionPayload,
        isFalse,
      );
    });
  });

  test('diagnostics mask pass / secret keys too', () {
    final out = LogRedaction.redact('{"user":"u","pass":"p1","secret":"s1"}');
    expect(out, isNot(contains('p1')));
    expect(out, isNot(contains('s1')));
  });
}
