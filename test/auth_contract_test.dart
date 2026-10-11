import 'package:colitu_vpn/colitu/api/models/auth_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registration sends only fields accepted by the control plane', () {
    const request = RegisterRequest(
      email: 'person@example.com',
      password: 'long-password',
      name: 'Person',
      deviceId: 'legacy-device-id',
      deviceName: 'iOS',
    );

    expect(request.toJson(), {
      'email': 'person@example.com',
      'password': 'long-password',
      'source': 'app:ios',
    });
  });

  test('registration carries the invite code only when there is one', () {
    const request = RegisterRequest(
      email: 'person@example.com',
      password: 'long-password',
      invite: 'ABC123XY',
    );

    expect(request.toJson(), {
      'email': 'person@example.com',
      'password': 'long-password',
      'source': 'app:ios',
      'invite': 'ABC123XY',
    });
    expect(
      const RegisterRequest(email: 'a@b.co', password: 'x', invite: '')
          .toJson()
          .containsKey('invite'),
      isFalse,
    );
  });

  test('decodes the snake case bearer token response', () {
    final response = AuthTokenResponse.fromJson({
      'access_token': 'access-token',
      'refresh_token': 'refresh-token',
      'token_type': 'Bearer',
      'expires_in': 900,
    });

    expect(response.tokens.accessToken, 'access-token');
    expect(response.tokens.refreshToken, 'refresh-token');
  });

  test('refresh uses the snake case request field', () {
    expect(const RefreshTokenRequest('refresh-token').toJson(), {
      'refresh_token': 'refresh-token',
    });
  });
}
