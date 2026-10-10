import 'dart:io';

import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/cert_pins.dart';
import 'package:colitu_vpn/colitu/api/endpoint_list.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final before = DateTime.utc(2027, 12, 31, 23, 59, 59);
  final after = DateTime.utc(2028, 1, 1);

  group('CertPins context choice', () {
    test('pinned until 2027-12-31T23:59:59Z, default trust after', () {
      expect(CertPins.expiresAt, DateTime.utc(2027, 12, 31, 23, 59, 59));
      expect(CertPins.active(DateTime.utc(2026, 10, 10)), isTrue);
      expect(CertPins.active(before), isTrue);
      expect(CertPins.active(before.add(const Duration(seconds: 1))), isFalse);
      expect(CertPins.active(after), isFalse);
    });

    test('the six PEMs parse, one certificate each', () {
      expect(CertPins.roots, hasLength(6));
      for (final pem in CertPins.roots) {
        expect('BEGIN CERTIFICATE'.allMatches(pem), hasLength(1));
        // Throws a TlsException on anything that is not a certificate.
        SecurityContext(
          withTrustedRoots: false,
        ).setTrustedCertificatesBytes(pem.codeUnits);
      }
      expect(CertPins.roots.toSet(), hasLength(6));
    });

    test('contexts build before and after the expiry', () {
      expect(CertPins.contextFor(before), isA<SecurityContext>());
      expect(CertPins.contextFor(after), isA<SecurityContext>());
      CertPins.newHttpClient(clock: () => before).close(force: true);
      CertPins.newHttpClient(clock: () => after).close(force: true);
    });
  });

  group('pinned client against a self-signed server', () {
    late Directory dir;
    late SecureServerSocket server;
    late String cert;
    var opensslOk = false;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('colitu_pin_test');
      try {
        final result = await Process.run('openssl', [
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
          '-subj', '/CN=localhost',
          '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
          '-keyout', '${dir.path}/key.pem',
          '-out', '${dir.path}/cert.pem',
        ]);
        opensslOk = result.exitCode == 0;
      } catch (_) {
        opensslOk = false;
      }
      if (!opensslOk) return;
      cert = '${dir.path}/cert.pem';
      final context = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey('${dir.path}/key.pem');
      server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((socket) {
        socket.listen((_) {
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
            'Content-Length: 2\r\nConnection: close\r\n\r\n{}',
          );
          socket.close();
        }, onError: (_) {});
      }, onError: (_) {});
    });

    tearDownAll(() async {
      if (opensslOk) await server.close();
      await dir.delete(recursive: true);
    });

    Dio pinnedDio() => Dio(BaseOptions(validateStatus: (s) => s != null))
      ..httpClientAdapter = CertPins.adapter(clock: () => before);

    test('is rejected and counts as a network-level failure', () async {
      if (!opensslOk) {
        markTestSkipped('openssl not available');
        return;
      }
      final url = 'https://localhost:${server.port}/';
      Object? caught;
      try {
        await pinnedDio().get<Object?>(url);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioException>());
      final error = caught as DioException;
      expect(CertPins.isTlsFailure(error), isTrue);
      expect(shouldFailOver(error, 'GET'), isTrue);
      expect(shouldFailOver(error, 'POST'), isTrue);
      final api = APIException.fromDio(error);
      expect(api.code, APIErrorCode.networkUnavailable);
      expect(api.statusCode, isNull);
    });

    test('the server itself works for a client that trusts its cert', () async {
      if (!opensslOk) {
        markTestSkipped('openssl not available');
        return;
      }
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(File(cert).readAsBytesSync());
      final dio = Dio()
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () => HttpClient(context: context),
        );
      final response = await dio.get<Object?>(
        'https://localhost:${server.port}/',
      );
      expect(response.statusCode, 200);
    });
  });
}
