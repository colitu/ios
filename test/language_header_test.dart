import 'dart:convert';
import 'dart:typed_data';

import 'package:colitu_vpn/colitu/api/language_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Map<String, dynamic>> sentHeaders(
    LanguageInterceptor interceptor, {
    Map<String, dynamic>? headers,
  }) async {
    late Map<String, dynamic> seen;
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..interceptors.add(interceptor)
      ..httpClientAdapter = _FakeAdapter((options) async {
        seen = Map.of(options.headers);
        return ResponseBody.fromString(
          jsonEncode({'ok': true}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
    await dio.get<dynamic>(
      '/client/bootstrap',
      options: Options(headers: headers),
    );
    return seen;
  }

  test('every request carries the app language', () async {
    expect(
      (await sentHeaders(
        LanguageInterceptor(language: () => 'tr'),
      ))['Accept-Language'],
      'tr',
    );
    expect(
      (await sentHeaders(
        LanguageInterceptor(language: () => ' RU '),
      ))['Accept-Language'],
      'ru',
    );
    // The app's choice replaces whatever the platform would send.
    final replaced = await sentHeaders(
      LanguageInterceptor(language: () => 'en'),
      headers: {'Accept-Language': 'de-DE,de;q=0.9'},
    );
    expect(replaced['Accept-Language'], 'en');
  });

  test('a language change applies to the next request', () async {
    var language = 'en';
    final interceptor = LanguageInterceptor(language: () => language);
    expect((await sentHeaders(interceptor))['Accept-Language'], 'en');
    language = 'ru';
    expect((await sentHeaders(interceptor))['Accept-Language'], 'ru');
  });

  test('only plain two-letter codes', () async {
    expect(
      (await sentHeaders(
        LanguageInterceptor(language: () => 'tr\r\nX-Evil: 1'),
      ))['Accept-Language'],
      isNull,
    );
    expect(LanguageInterceptor.headerValue(''), isNull);
    expect(LanguageInterceptor.headerValue('tur'), isNull);
    expect(LanguageInterceptor.headerValue(null), isNull);
    expect(LanguageInterceptor.headerValue('TR'), 'tr');
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
