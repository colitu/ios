import 'package:colitu_vpn/colitu/config/app_environment.dart';

/// Client routes exposed by the Colitu panel (`api.colitu.com/api/v1`).
/// The full contract lives in the panel repository: `api/client/openapi.yaml`.
abstract final class APIEndpoint {
  static Uri get baseUrl => AppEnvironment.apiBaseUrl;

  static const authLogin = '/auth/login';
  static const authRegister = '/auth/register';
  static const authRefresh = '/auth/refresh';
  static const authLogout = '/auth/logout';
  static const me = '/me';
  static const emailSend = '/auth/email/send';
  static const emailVerify = '/auth/email/verify';
  static const passwordForgot = '/auth/password/forgot';
  static const passwordReset = '/auth/password/reset';
  static const linkLookup = '/auth/link/lookup';
  static const linkApprove = '/auth/link/approve';
  static const linkDeny = '/auth/link/deny';

  static const supportConversations = '/support/conversations';
  static const supportUnread = '/support/unread';
  static String supportThread(String id) => '/support/conversations/${Uri.encodeComponent(id)}';
  static String supportMessages(String id) => '/support/conversations/${Uri.encodeComponent(id)}/messages';
  static String supportAttachment(String id) => '/support/attachments/${Uri.encodeComponent(id)}';

  static const userDevices = '/devices';
  static const registerDevice = '/devices/register';
  static const clientBootstrap = '/client/bootstrap';
  static const userPreferences = '/me/preferences';
  static const configRefresh = '/config/refresh';
  static const protocolObservations = '/client/protocol-observations';

  static const vpnServers = '/servers';
  static const vpnConfig = '/config';
  static const vpnStatus = '/client/bootstrap';
  static const vpnStats = '/me/usage';

  static const subscription = '/billing/subscription';

  static const billingProducts = '/billing/catalog';
  static const billingPaymentMethods = '/billing/payment-methods';
  static const billingQuote = '/billing/quote';
  static const billingCheckout = '/billing/checkout';
  static const billingOrders = '/billing/orders';
}
