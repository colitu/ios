import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A response body went over the size limit of its request.
class ResponseTooLargeException implements Exception {
  const ResponseTooLargeException(this.limit);

  final int limit;

  @override
  String toString() => 'Response larger than $limit bytes';
}

/// Caps how much of a response body is read into memory: a declared
/// Content-Length over the limit fails at once, a body that grows past it
/// fails as soon as it does (instead of being buffered whole first). The
/// limit is [defaultLimit] unless a request sets [extraKey] in its `extra`.
class BodyLimitAdapter implements HttpClientAdapter {
  BodyLimitAdapter(this._inner, {this.defaultLimit = defaultApiLimit});

  /// JSON from the API: the largest answers (server list, config with
  /// candidates) stay well under this.
  static const defaultApiLimit = 4 << 20;

  /// The signed endpoint list.
  static const endpointListLimit = 256 << 10;

  /// `Options(extra: {BodyLimitAdapter.extraKey: bytes})` overrides the limit.
  static const extraKey = 'colituMaxResponseBytes';

  final HttpClientAdapter _inner;
  final int defaultLimit;

  int limitFor(RequestOptions options) {
    final value = options.extra[extraKey];
    return value is int && value > 0 ? value : defaultLimit;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final limit = limitFor(options);
    final body = await _inner.fetch(options, requestStream, cancelFuture);
    final declared = int.tryParse(
      body.headers[Headers.contentLengthHeader]?.firstOrNull ?? '',
    );
    if (declared != null && declared > limit) {
      // Not listening and cancelling drops the connection unread.
      unawaited(body.stream.listen(null).cancel());
      throw ResponseTooLargeException(limit);
    }
    body.stream = capStream(body.stream, limit);
    return body;
  }

  /// [source] until more than [limit] bytes have come, then an error (and
  /// the source is cancelled).
  static Stream<Uint8List> capStream(Stream<Uint8List> source, int limit) {
    var received = 0;
    StreamSubscription<Uint8List>? sub;
    late final StreamController<Uint8List> capped;
    capped = StreamController<Uint8List>(
      onListen: () {
        sub = source.listen(
          (chunk) {
            received += chunk.length;
            if (received > limit) {
              unawaited(sub?.cancel());
              capped.addError(ResponseTooLargeException(limit));
              unawaited(capped.close());
              return;
            }
            capped.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            capped.addError(error, stack);
            unawaited(capped.close());
          },
          onDone: () {
            if (!capped.isClosed) unawaited(capped.close());
          },
          cancelOnError: true,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    return capped.stream;
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
