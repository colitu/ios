import 'package:colitu_vpn/core/tools/logger.dart';

class DocURLHelper {
  static final _colituSupport = Uri.parse("https://colitu.com/support");
  static final _colituCredits = Uri.parse("https://colitu.com/legal/terms");
  static final _colituPrivacy = Uri.parse("https://colitu.com/legal/privacy");
  static final _colituTerms = Uri.parse("https://colitu.com/legal/terms");

  static Uri docUri() {
    ygLogger("$_colituSupport");
    return _colituSupport;
  }

  static Uri creditsUri() {
    ygLogger("$_colituCredits");
    return _colituCredits;
  }

  static Uri privacyUri() {
    ygLogger("$_colituPrivacy");
    return _colituPrivacy;
  }

  static Uri termsUri() {
    ygLogger("$_colituTerms");
    return _colituTerms;
  }
}
