import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:dio/dio.dart';

/// Sends the app language ("ru", "tr", "en") as Accept-Language with every
/// API request, so the panel keeps the account's language (users.locale) and
/// writes its notifications and e-mails in it. Only the language picked in
/// the app, never the phone's full locale list.
class LanguageInterceptor extends Interceptor {
  LanguageInterceptor({String Function()? language})
    : _language = language ?? (() => ColituLoc.I.language);

  final String Function() _language;

  static final _code = RegExp(r'^[a-z]{2}$');

  /// The language code as header value; null for anything that is not a
  /// plain two-letter code.
  static String? headerValue(String? language) {
    final value = (language ?? '').trim().toLowerCase();
    return _code.hasMatch(value) ? value : null;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final value = headerValue(_language());
    if (value != null) {
      options.headers['Accept-Language'] = value;
    }
    handler.next(options);
  }
}
