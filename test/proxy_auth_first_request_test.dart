import 'dart:convert';
import 'dart:io';

import 'package:colitu_vpn/colitu/services/warm_spare.dart';
import 'package:flutter_test/flutter_test.dart';

/// Xray 26.10's HTTP inbound answers a request without credentials with 407
/// and closes the connection; a client that only sends them after a 407 on
/// the same connection never gets through (the Android warm spare check
/// failed that way). The app's check proxies take a password, so the
/// client must send it with the first request.
void main() {
  test(
    'the check client sends the proxy credentials with the first request',
    () async {
      final seen = <String?>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final check = ColituVerifyProxy.random(proxy.port);
      final expected =
          'Basic ${base64.encode(utf8.encode('${check.user}:${check.pass}'))}';
      proxy.listen((request) async {
        final auth = request.headers.value(
          HttpHeaders.proxyAuthorizationHeader,
        );
        seen.add(auth);
        if (auth != expected) {
          // Like Xray: refuse and close, no second chance on this connection.
          request.response
            ..statusCode = HttpStatus.proxyAuthenticationRequired
            ..persistentConnection = false;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = HttpClient()..findProxy = (_) => check.directive;
      try {
        final request = await client.getUrl(
          Uri.parse('http://check.example.test/generate_204'),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.noContent);
        expect(seen, [expected], reason: 'one request, credentials included');
      } finally {
        client.close(force: true);
        await proxy.close(force: true);
      }
    },
  );
}
