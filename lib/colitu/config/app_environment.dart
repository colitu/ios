import 'package:flutter/foundation.dart';

abstract final class AppEnvironment {
  static const appName = 'Colitu Secure VPN';
  static const appBundleId = 'com.colitu.vpn';
  /// Developer/staging override. When set to something other than the
  /// production base, only this base is used: no failover and no refresh of
  /// the signed endpoint list.
  static const _apiBaseOverride = String.fromEnvironment('COLITU_API_BASE_URL');
  static const primaryApiBase = 'https://api.colitu.com/api/v1';
  static bool get hasApiBaseOverride {
    final value = _apiBaseOverride.trim().replaceFirst(RegExp(r'/+$'), '');
    // Release builds pass the production base explicitly; that is no override.
    return value.isNotEmpty && value != primaryApiBase;
  }

  /// Alternative origins for the API and the signed list. They are not in the
  /// public source: release builds pass them as a comma-separated list with
  /// `--dart-define=COLITU_MIRRORS=https://...,https://...`.
  static final List<String> mirrorOrigins = parseMirrorOrigins(
    const String.fromEnvironment('COLITU_MIRRORS'),
  );

  /// The `https://` origins of a comma-separated [value], in order.
  static List<String> parseMirrorOrigins(String value) => List.unmodifiable(
    value
        .split(',')
        .map((url) => url.trim().replaceFirst(RegExp(r'/+$'), ''))
        .where((url) {
          final uri = Uri.tryParse(url);
          return uri != null &&
              uri.isScheme('https') &&
              uri.host.isNotEmpty &&
              !uri.hasQuery &&
              !uri.hasFragment;
        }),
  );

  /// API bases in order, used until a signed list has been accepted.
  static List<String> apiBasesFor(List<String> mirrors) => [
    primaryApiBase,
    for (final origin in mirrors) '$origin/capi/v1',
  ];

  /// Where the signed endpoint list is published.
  static List<String> listUrlsFor(List<String> mirrors) => [
    'https://colitu.com/downloads/endpoints.json',
    for (final origin in mirrors) '$origin/downloads/endpoints.json',
  ];

  static List<String> get builtInApiBases => apiBasesFor(mirrorOrigins);
  static List<String> get builtInListUrls => listUrlsFor(mirrorOrigins);

  /// Key that signs the endpoint list (ECDSA P-256).
  static const endpointKeyId = 'e1';
  static const endpointPublicKeyPem = """
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEhv55BVmvEisYIRhkejn+4Leuf0KW
6jrrRvSL4cu4W09jUwc6HTIcq+YUSG1kJ5AF7qK7PlBtf+xRMTQMGM+xPg==
-----END PUBLIC KEY-----
""";

  static final Uri apiBaseUrl = Uri.parse(
    (hasApiBaseOverride ? _apiBaseOverride.trim() : primaryApiBase)
        .replaceFirst(RegExp(r'/+$'), ''),
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
