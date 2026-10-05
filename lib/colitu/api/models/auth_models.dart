import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';

class LoginRequest {
  final String email;
  final String password;
  final String? deviceId;

  const LoginRequest({
    required this.email,
    required this.password,
    this.deviceId,
  });

  Map<String, dynamic> toJson() => {'email': email, 'password': password};
}

class RegisterRequest {
  final String email;
  final String password;
  final String? name;
  final String? deviceId;
  final String? deviceName;

  const RegisterRequest({
    required this.email,
    required this.password,
    this.name,
    this.deviceId,
    this.deviceName,
  });

  Map<String, dynamic> toJson() => {'email': email, 'password': password};
}

class RefreshTokenRequest {
  final String refreshToken;

  const RefreshTokenRequest(this.refreshToken);

  Map<String, dynamic> toJson() => {'refresh_token': refreshToken};
}

class AuthTokenResponse {
  final AuthTokens tokens;

  const AuthTokenResponse({required this.tokens});

  factory AuthTokenResponse.fromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token'] as String?;
    final refreshToken = json['refresh_token'] as String?;
    final tokenType = json['token_type'];
    final expiresIn = json['expires_in'];
    if (accessToken == null ||
        accessToken.isEmpty ||
        refreshToken == null ||
        refreshToken.isEmpty ||
        tokenType != 'Bearer' ||
        expiresIn is! int ||
        expiresIn < 1) {
      throw const FormatException(
        'Auth response does not match the token contract',
      );
    }
    return AuthTokenResponse(
      tokens: AuthTokens(accessToken: accessToken, refreshToken: refreshToken),
    );
  }
}

class AuthResponse {
  final AuthTokens tokens;
  final ColituUser user;

  const AuthResponse({required this.tokens, required this.user});

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    final accessToken =
        json['accessToken'] as String? ??
        json['token'] as String? ??
        json['jwt'] as String?;
    final userJson = json['user'];
    if (accessToken == null || accessToken.isEmpty) {
      throw const FormatException('Auth response is missing accessToken');
    }
    if (userJson is! Map<String, dynamic>) {
      throw const FormatException('Auth response is missing user');
    }
    return AuthResponse(
      tokens: AuthTokens(
        accessToken: accessToken,
        refreshToken: json['refreshToken'] as String?,
      ),
      user: ColituUser.fromJson(userJson),
    );
  }
}
