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

  test('sign-up guard errors keep their backend code and message', () {
    for (final (status, code) in [
      (400, 'DISPOSABLE_EMAIL'),
      (400, 'PASSWORD_BREACHED'),
      (429, 'SIGNUP_IP_LIMIT'),
    ]) {
      final error = APIException.fromResponse(
        Response<Object?>(
          requestOptions: RequestOptions(path: '/auth/register'),
          statusCode: status,
          data: {'error': {'code': code, 'message': 'x'}},
        ),
      );
      expect(error.backendCode, code);
      expect(error.statusCode, status);
    }
  });
}
