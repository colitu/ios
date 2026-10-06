import 'package:flutter/foundation.dart';

abstract final class AppEnvironment {
  static const appName = 'Colitu Secure VPN';
  static const appBundleId = 'com.colitu.vpn';
  static final Uri apiBaseUrl = Uri.parse(
    const String.fromEnvironment(
      'COLITU_API_BASE_URL',
      defaultValue: 'https://api.colitu.com/api/v1',
    ).replaceFirst(RegExp(r'/+$'), ''),
  );

  static const enableApiDebugLogging = kDebugMode;

  /// Public website; account management and legal pages live there.
  static const webBaseUrl = 'https://colitu.com';

  /// Customer account: plans, renewals and devices are managed there, not in
  /// the app.
  static const accountUrl = 'https://app.colitu.com';

  /// Two-step sign-in is set up here only (the apps answer the challenge).
  static const securitySettingsUrl = 'https://colitu.com/account/security';

  /// Connection details for other apps and devices (web only for now).
  static const manualConfigUrl = 'https://colitu.com/account/manual-config';
  static const supportEmail = 'support@colitu.com';

  /// Public source code (GPL-3.0).
  static const sourceCodeUrl = 'https://github.com/colitu/ios';
  static const companyName = 'COLITU LIMITED';
}
