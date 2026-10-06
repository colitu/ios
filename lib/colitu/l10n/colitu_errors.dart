import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';

/// Thrown when the tunnel came up but no traffic flows through it.
class ColituVerifyException implements Exception {
  const ColituVerifyException([this.tunnelFailure]);

  /// Last `core_start_failed` / `core_crashed` reason from the extension's
  /// stability log, when one was recorded.
  final String? tunnelFailure;

  @override
  String toString() => 'ColituVerifyException(${tunnelFailure ?? ''})';
}

/// Thrown when the plan does not allow connecting; the UI sends the user to
/// the plan page instead of showing a plain error.
class ColituPlanRequiredException implements Exception {
  const ColituPlanRequiredException();
}

/// Localized, user-facing message for any failure the app can surface.
/// Mirrors `ColituAuthService.FriendlyMessage` in the Windows app.
String colituErrorMessage(Object error, {bool signingIn = false}) {
  final loc = ColituLoc.I;
  if (error is ColituPlanRequiredException) return loc['err.noPlan'];
  if (error is ColituVerifyException) {
    return switch (error.tunnelFailure) {
      'no_socket_fd' => loc['err.tun'],
      'core_process_failed' ||
      'core_not_running_after_start' ||
      'core_not_running' => loc['err.engine'],
      _ => loc['err.verify'],
    };
  }
  if (error is DioException) {
    return colituErrorMessage(APIException.fromDio(error), signingIn: signingIn);
  }
  if (error is TimeoutException) return loc['err.network'];
  if (error is PlatformException) return loc['err.tun'];
  if (error is APIException) {
    switch (error.backendCode) {
      case 'AUTH_INVALID_CREDENTIALS':
        return loc['err.credentials'];
      case 'INVALID_REGISTRATION':
        return loc['err.registration'];
      case 'RATE_LIMITED':
        return loc['err.rateLimited'];
      case 'DEVICE_LIMIT_REACHED':
      case 'DEVICE_LIMIT_EXCEEDED':
        return loc['err.deviceLimit'];
      case 'REGION_NOT_SUPPORTED':
        return loc['err.region'];
      case 'TRIAL_ALREADY_USED':
        return loc['err.trialUsed'];
      case 'EMAIL_NOT_VERIFIED':
        return loc['err.notVerified'];
      case 'VERIFICATION_CODE_INVALID':
        return loc['verify.err.invalid'];
      case 'VERIFICATION_CODE_EXPIRED':
        return loc['verify.err.expired'];
      case 'VERIFICATION_RATE_LIMITED':
        return loc['verify.err.wait'];
      case 'AUTH_INVALID_PASSWORD':
        return loc['auth.err.password'];
      case 'LINK_NOT_FOUND':
      case 'LINK_EXPIRED':
      case 'LINK_DENIED':
        return loc['link.invalid'];
      case 'EMAIL_DELIVERY_UNAVAILABLE':
        return loc['verify.err.mail'];
      case 'SUPPORT_FILE_TOO_LARGE':
      case 'SUPPORT_FILE_TYPE':
        return loc['support.err.file'];
      case 'SUPPORT_UNAVAILABLE':
        return loc['support.err.unavailable'];
      case 'SUPPORT_CONVERSATION_CLOSED':
        return loc['support.closed'];
      case 'SUPPORT_INVALID_INPUT':
        return loc['support.err.subject'];
      case 'ENTITLEMENT_INACTIVE':
      case 'ENTITLEMENT_EXPIRED':
      case 'SUBSCRIPTION_REQUIRED':
        return loc['err.noPlan'];
      case 'QUOTA_EXCEEDED':
      case 'FREE_DAILY_LIMIT_REACHED':
        return loc['err.quota'];
      case 'NO_HEALTHY_NODES':
      case 'CONFIG_NOT_AVAILABLE':
      case 'INVALID_PREFERENCE':
        return loc['err.noServers'];
      case 'MULTIHOP_ROUTE_NOT_FOUND':
        return loc['multihop.gone'];
      case 'MFA_INVALID_CODE':
        return loc['mfa.err.invalid'];
      case 'MFA_TOKEN_EXPIRED':
        return loc['mfa.err.expired'];
      case 'MFA_REQUIRED_UPDATE_APP':
        return loc['mfa.err.update'];
      case 'DEVICE_OVER_LIMIT':
        return loc['paused.title'];
    }
    switch (error.code) {
      case APIErrorCode.unauthorized:
      case APIErrorCode.tokenExpired:
        return signingIn ? loc['err.credentials'] : loc['auth.expired'];
      case APIErrorCode.deviceDisconnected:
        return loc['auth.expired'];
      case APIErrorCode.rateLimited:
        return loc['err.rateLimited'];
      case APIErrorCode.subscriptionInactive:
      case APIErrorCode.premiumRequired:
      case APIErrorCode.serverNotAllowed:
        return loc['err.noPlan'];
      case APIErrorCode.freeDailyLimitReached:
        return loc['err.quota'];
      case APIErrorCode.serverUnavailable:
      case APIErrorCode.configMissing:
        return loc['err.noServers'];
      case APIErrorCode.networkUnavailable:
      case APIErrorCode.backendUnavailable:
        return loc['err.network'];
      case APIErrorCode.vpnPermissionDenied:
        return loc['err.permission'];
      case APIErrorCode.mfaInvalidCode:
        return loc['mfa.err.invalid'];
      case APIErrorCode.mfaTokenExpired:
        return loc['mfa.err.expired'];
      case APIErrorCode.mfaUpdateRequired:
        return loc['mfa.err.update'];
      case APIErrorCode.deviceOverLimit:
        return loc['paused.title'];
      case APIErrorCode.mfaRequired:
        return loc['mfa.title'];
      case APIErrorCode.emailNotVerified:
      case APIErrorCode.purchaseCancelled:
      case APIErrorCode.purchasePending:
      case APIErrorCode.purchaseVerificationFailed:
      case APIErrorCode.decodingFailed:
      case APIErrorCode.unknown:
        if (signingIn && (error.statusCode == 400 || error.statusCode == 409)) {
          return loc['err.registration'];
        }
        if ((error.statusCode ?? 0) >= 500) return loc['err.network'];
        return loc['err.generic'];
    }
  }
  final text = error.toString().toLowerCase();
  if (text.contains('vpnstartfailed') ||
      text.contains('could not start the vpn tunnel')) {
    return loc['err.tun'];
  }
  if (text.contains('did not confirm')) return loc['err.engine'];
  return loc['err.generic'];
}
