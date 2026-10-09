import 'dart:async';

import 'package:dio/dio.dart';

enum APIErrorCode {
  unauthorized,
  tokenExpired,
  networkUnavailable,
  backendUnavailable,
  subscriptionInactive,
  configMissing,
  serverUnavailable,
  vpnPermissionDenied,
  purchaseCancelled,
  purchasePending,
  purchaseVerificationFailed,
  premiumRequired,
  serverNotAllowed,
  freeDailyLimitReached,
  rateLimited,
  deviceDisconnected,
  emailNotVerified,
  decodingFailed,

  /// Sign-in needs the code from the authenticator app (two-step sign-in).
  mfaRequired,

  /// The two-step code (or recovery code) is wrong; try again.
  mfaInvalidCode,

  /// The sign-in step expired; start again with e-mail and password.
  mfaTokenExpired,

  /// The account needs two-step sign-in and this build cannot do it.
  mfaUpdateRequired,

  /// The plan allows fewer devices than are active: this one is paused.
  deviceOverLimit,
  unknown,
}

class APIException implements Exception {
  final APIErrorCode code;
  final String message;
  final int? statusCode;
  final bool terminalAuthFailure;

  /// Machine-readable code from the panel's error envelope
  /// (`AUTH_INVALID_CREDENTIALS`, `DEVICE_LIMIT_REACHED`, …), when present.
  final String? backendCode;

  /// The response body of errors that carry data the app needs
  /// (`MFA_REQUIRED`: `mfa_token`; `DEVICE_OVER_LIMIT`: `active_devices`).
  final Map<String, dynamic>? details;

  // A cached credential must never override a control-plane access decision.
  bool get allowsConfigFallback =>
      !terminalAuthFailure &&
      ((statusCode == null && code == APIErrorCode.networkUnavailable) ||
          const [502, 503, 504].contains(statusCode));

  const APIException(
    this.code,
    this.message, {
    this.statusCode,
    this.terminalAuthFailure = false,
    this.backendCode,
    this.details,
  });

  APIException withBackendCode(String? code) {
    if (code == null || code.isEmpty || backendCode == code) return this;
    return APIException(
      this.code,
      message,
      statusCode: statusCode,
      terminalAuthFailure: terminalAuthFailure,
      backendCode: code,
      details: details,
    );
  }

  APIException _withDetails(Object? data) {
    if (data is! Map<String, dynamic> || !_detailCodes.contains(backendCode)) {
      return this;
    }
    return APIException(
      code,
      message,
      statusCode: statusCode,
      terminalAuthFailure: terminalAuthFailure,
      backendCode: backendCode,
      details: data,
    );
  }

  static const _detailCodes = {
    'MFA_REQUIRED',
    'MFA_INVALID_CODE',
    'DEVICE_OVER_LIMIT',
  };

  factory APIException.fromResponse(Response<dynamic> response) {
    return APIException._fromResponse(response)
        .withBackendCode(_codeFromData(response.data))
        ._withDetails(response.data);
  }

  factory APIException._fromResponse(Response<dynamic> response) {
    final status = response.statusCode;
    final backendCode = _codeFromData(response.data);
    final terminalAuthFailure =
        _terminalFromData(response.data) || _isTerminalAuthCode(backendCode);
    final mapped = _mappedBackendError(
      backendCode,
      status,
      terminalAuthFailure: terminalAuthFailure,
    );
    if (mapped != null) {
      return mapped;
    }
    final message = _messageFromData(response.data);
    if (status == 401) {
      return APIException(
        APIErrorCode.unauthorized,
        message ?? 'Unauthorized',
        statusCode: status,
        terminalAuthFailure: terminalAuthFailure,
      );
    }
    if (status == 429) {
      return const APIException(
        APIErrorCode.rateLimited,
        'Too many attempts. Please wait a minute and try again.',
        statusCode: 429,
      );
    }
    if (status == 403) {
      return APIException(
        APIErrorCode.subscriptionInactive,
        message ?? 'Access denied',
        statusCode: status,
      );
    }
    if (status == 404) {
      return APIException(
        APIErrorCode.configMissing,
        message ?? 'Resource not found',
        statusCode: status,
      );
    }
    if (status == 503) {
      return APIException(
        APIErrorCode.serverUnavailable,
        friendlyApiErrorMessage(
          APIErrorCode.serverUnavailable,
          statusCode: status,
        ),
        statusCode: status,
      );
    }
    if (status != null && status >= 500) {
      return APIException(
        APIErrorCode.backendUnavailable,
        friendlyApiErrorMessage(APIErrorCode.backendUnavailable),
        statusCode: status,
      );
    }
    return APIException(
      APIErrorCode.unknown,
      message ?? friendlyApiErrorMessage(APIErrorCode.unknown),
      statusCode: status,
    );
  }

  factory APIException.fromDio(DioException error) {
    final response = error.response;
    if (response != null) {
      return APIException.fromResponse(response);
    }
    final status = response?.statusCode;
    final backendCode = _codeFromData(error.response?.data);
    final mapped = _mappedBackendError(
      backendCode,
      status,
      terminalAuthFailure:
          _terminalFromData(error.response?.data) ||
          _isTerminalAuthCode(backendCode),
    );
    if (mapped != null) {
      return mapped;
    }
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return APIException(
        APIErrorCode.networkUnavailable,
        friendlyMessageForNetworkFailure(error),
        statusCode: status,
      );
    }
    return APIException(
      APIErrorCode.unknown,
      friendlyApiErrorMessage(APIErrorCode.unknown),
      statusCode: status,
    );
  }

  static String? _messageFromData(Object? data) {
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      final message = error is Map<String, dynamic>
          ? error['message']
          : data['message'] ?? error ?? data['detail'];
      return message is String ? message : null;
    }
    return null;
  }

  static String? _codeFromData(Object? data) {
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      final code = error is Map<String, dynamic>
          ? error['code']
          : error ?? data['code'];
      return code is String ? code : null;
    }
    return null;
  }

  static bool _terminalFromData(Object? data) {
    if (data is Map<String, dynamic>) {
      return data['terminal'] == true;
    }
    return false;
  }

  static bool _isTerminalAuthCode(String? code) {
    switch (code) {
      case 'SESSION_REVOKED':
      case 'DEVICE_DISCONNECTED':
      case 'ACCOUNT_DELETED':
      case 'REFRESH_TOKEN_COMPROMISED':
      case 'REFRESH_SESSION_EXPIRED':
      case 'USER_DISABLED':
      case 'DEVICE_REVOKED':
      case 'DEVICE_NOT_FOUND':
      case 'DEVICE_TOKEN_MISMATCH':
      case 'AUTH_REFRESH_REUSED':
        return true;
    }
    return false;
  }

  static APIException? _mappedBackendError(
    String? code,
    int? statusCode, {
    bool terminalAuthFailure = false,
  }) {
    switch (code) {
      case 'SUBSCRIPTION_REQUIRED':
      case 'ENTITLEMENT_INACTIVE':
      case 'ENTITLEMENT_EXPIRED':
        return APIException(
          APIErrorCode.subscriptionInactive,
          'Please choose a plan to continue.',
          statusCode: statusCode,
        );
      case 'AUTH_INVALID_CREDENTIALS':
        return APIException(
          APIErrorCode.unauthorized,
          'Email or password is incorrect.',
          statusCode: statusCode,
        );
      case 'INVALID_REGISTRATION':
        return APIException(
          APIErrorCode.unknown,
          'This email cannot be registered.',
          statusCode: statusCode,
        );
      case 'DISPOSABLE_EMAIL':
        return APIException(
          APIErrorCode.unknown,
          'Temporary e-mail addresses are not accepted.',
          statusCode: statusCode,
        );
      case 'PASSWORD_BREACHED':
        return APIException(
          APIErrorCode.unknown,
          'This password appears in a known data breach.',
          statusCode: statusCode,
        );
      case 'SIGNUP_IP_LIMIT':
        return APIException(
          APIErrorCode.rateLimited,
          'Too many accounts were created from this network recently.',
          statusCode: statusCode,
        );
      case 'DEVICE_LIMIT_REACHED':
      case 'DEVICE_LIMIT_EXCEEDED':
        return APIException(
          APIErrorCode.subscriptionInactive,
          'Device limit reached. Remove a device from your account.',
          statusCode: statusCode,
        );
      case 'QUOTA_EXCEEDED':
        return APIException(
          APIErrorCode.freeDailyLimitReached,
          'Your traffic quota has been exhausted.',
          statusCode: statusCode,
        );
      case 'INVALID_PREFERENCE':
        return APIException(
          APIErrorCode.serverUnavailable,
          'This location is not available right now.',
          statusCode: statusCode,
        );
      case 'PREMIUM_REQUIRED':
        return APIException(
          APIErrorCode.premiumRequired,
          'Please choose a Premium plan to use this server.',
          statusCode: statusCode,
        );
      case 'SERVER_NOT_ALLOWED':
        return APIException(
          APIErrorCode.serverNotAllowed,
          'This server is not available for your plan.',
          statusCode: statusCode,
        );
      case 'CONFIG_UNAVAILABLE':
      case 'CONFIG_NOT_AVAILABLE':
      case 'CONFIG_NOT_READY':
      case 'VPN_CONFIG_UNAVAILABLE':
        return APIException(
          APIErrorCode.configMissing,
          'Connection setup failed. Please try again.',
          statusCode: statusCode,
        );
      case 'NO_HEALTHY_NODES':
        return APIException(
          APIErrorCode.serverUnavailable,
          'No working VPN location is available right now. Please try again shortly.',
          statusCode: statusCode,
        );
      case 'FREE_DAILY_LIMIT_REACHED':
        return APIException(
          APIErrorCode.freeDailyLimitReached,
          'Your traffic quota has been exhausted. Upgrade or wait for the next billing period.',
          statusCode: statusCode,
        );
      case 'RATE_LIMITED':
        return APIException(
          APIErrorCode.rateLimited,
          'Too many attempts. Please wait a minute and try again.',
          statusCode: statusCode,
        );
      case 'DEVICE_DISCONNECTED':
      case 'DEVICE_REVOKED':
        return APIException(
          APIErrorCode.deviceDisconnected,
          'This device was disconnected. Please sign in again.',
          statusCode: statusCode,
          terminalAuthFailure: terminalAuthFailure,
        );
      case 'REFRESH_SESSION_EXPIRED':
        return APIException(
          APIErrorCode.tokenExpired,
          'Session expired.',
          statusCode: statusCode,
          terminalAuthFailure: terminalAuthFailure,
        );
      case 'SESSION_REVOKED':
      case 'ACCOUNT_DELETED':
      case 'REFRESH_TOKEN_COMPROMISED':
      case 'AUTH_REFRESH_REUSED':
      case 'USER_DISABLED':
        return APIException(
          APIErrorCode.unauthorized,
          'Please sign in again.',
          statusCode: statusCode,
          terminalAuthFailure: terminalAuthFailure,
        );
      case 'EMAIL_NOT_VERIFIED':
        return APIException(
          APIErrorCode.emailNotVerified,
          'Please verify your email to continue.',
          statusCode: statusCode,
        );
      case 'MFA_REQUIRED':
        return APIException(
          APIErrorCode.mfaRequired,
          'Enter the code from your authenticator app.',
          statusCode: statusCode,
        );
      case 'MFA_INVALID_CODE':
        return APIException(
          APIErrorCode.mfaInvalidCode,
          'The code is not correct.',
          statusCode: statusCode,
        );
      case 'MFA_TOKEN_EXPIRED':
        return APIException(
          APIErrorCode.mfaTokenExpired,
          'The sign-in took too long. Please sign in again.',
          statusCode: statusCode,
        );
      case 'MFA_REQUIRED_UPDATE_APP':
        return APIException(
          APIErrorCode.mfaUpdateRequired,
          'Update Colitu to sign in with two-step verification.',
          statusCode: statusCode,
        );
      case 'DEVICE_OVER_LIMIT':
        return APIException(
          APIErrorCode.deviceOverLimit,
          'This device is paused: your plan allows fewer devices.',
          statusCode: statusCode,
        );
    }
    return null;
  }

  @override
  String toString() => message;
}

String friendlyMessageForError(Object error, {String localeCode = 'en'}) {
  if (error is APIException) {
    return friendlyApiErrorMessage(
      error.code,
      statusCode: error.statusCode,
      localeCode: localeCode,
      fallback: error.message,
    );
  }
  if (error is DioException) {
    return friendlyMessageForError(
      APIException.fromDio(error),
      localeCode: localeCode,
    );
  }
  if (error is TimeoutException) {
    return _localized(
      localeCode,
      tr: 'İstek zaman aşımına uğradı. Lütfen bağlantınızı kontrol edip tekrar deneyin.',
      en: 'The request timed out. Please check your connection and try again.',
    );
  }
  return friendlyApiErrorMessage(APIErrorCode.unknown, localeCode: localeCode);
}

String friendlyMessageForNetworkFailure(
  DioException error, {
  String localeCode = 'en',
}) {
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout) {
    return _localized(
      localeCode,
      tr: 'İstek zaman aşımına uğradı. Lütfen bağlantınızı kontrol edip tekrar deneyin.',
      en: 'The request timed out. Please check your connection and try again.',
    );
  }
  return _localized(
    localeCode,
    tr: 'Ağ bağlantısı kurulamadı. Lütfen bağlantınızı kontrol edip tekrar deneyin.',
    en: 'Network connection failed. Please check your connection and try again.',
  );
}

String friendlyApiErrorMessage(
  APIErrorCode code, {
  int? statusCode,
  String localeCode = 'en',
  String? fallback,
}) {
  if (code == APIErrorCode.serverUnavailable) {
    return _localized(
      localeCode,
      tr: 'Sunucu şu anda yoğun veya geçici olarak kullanılamıyor. Lütfen biraz sonra tekrar deneyin.',
      en: 'Server is temporarily unavailable. Please try again later.',
    );
  }
  switch (code) {
    case APIErrorCode.backendUnavailable:
      return _localized(
        localeCode,
        tr: 'Sunucuya şu anda ulaşılamıyor. Lütfen biraz sonra tekrar deneyin.',
        en: 'Server is temporarily unavailable. Please try again later.',
      );
    case APIErrorCode.networkUnavailable:
      return _localized(
        localeCode,
        tr: 'Ağ bağlantısı kurulamadı. Lütfen bağlantınızı kontrol edip tekrar deneyin.',
        en: 'Network connection failed. Please check your connection and try again.',
      );
    case APIErrorCode.unknown:
      return _localized(
        localeCode,
        tr: 'Bir sorun oluştu. Lütfen tekrar deneyin.',
        en: 'Something went wrong. Please try again.',
      );
    default:
      return fallback ??
          _localized(
            localeCode,
            tr: 'Bir sorun oluştu. Lütfen tekrar deneyin.',
            en: 'Something went wrong. Please try again.',
          );
  }
}

String _localized(String localeCode, {required String tr, required String en}) {
  return localeCode.toLowerCase().startsWith('tr') ? tr : en;
}
