import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production API defaults to the live Colitu host', () {
    expect(
      AppEnvironment.apiBaseUrl,
      Uri.parse('https://api.colitu.com/api/v1'),
    );
  });
}
