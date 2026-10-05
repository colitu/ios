import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('503 config errors retain their actionable backend meaning', () {
    final error = APIException.fromResponse(
      Response<Object?>(
        requestOptions: RequestOptions(path: '/config'),
        statusCode: 503,
        data: {
          'error': {
            'code': 'CONFIG_NOT_AVAILABLE',
            'message': 'configuration is unavailable',
          },
        },
      ),
    );

    expect(error.code, APIErrorCode.configMissing);
    expect(
      friendlyMessageForError(error),
      'Connection setup failed. Please try again.',
    );
  });

  test('503 node selection errors remain server availability errors', () {
    final error = APIException.fromResponse(
      Response<Object?>(
        requestOptions: RequestOptions(path: '/config'),
        statusCode: 503,
        data: {
          'error': {
            'code': 'NO_HEALTHY_NODES',
            'message': 'no healthy compatible nodes',
          },
        },
      ),
    );

    expect(error.code, APIErrorCode.serverUnavailable);
    expect(
      friendlyMessageForError(error),
      'Server is temporarily unavailable. Please try again later.',
    );
  });
}
