/// Masks credentials and personal data in log text before it leaves the
/// device in a diagnostics report (the same rules as the Android and Windows
/// apps): user parts of share links, tokens, keys and passwords in query
/// strings and JSON, URL credentials and e-mail addresses.
class LogRedaction {
  LogRedaction._();

  static final _email = RegExp(
    r'(?<![/\w.%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b',
  );
  static final _base64Link = RegExp(
    r'((?:vmess|ss)://)[A-Za-z0-9+/=_-]{16,}',
    caseSensitive: false,
  );
  static final _shareLink = RegExp(
    r'((?:vless|vmess|trojan|hysteria2|hy2|ss|tuic|socks|socks5)://)[^@\s/]+@',
    caseSensitive: false,
  );
  static final _bearer = RegExp(r'Bearer\s+[A-Za-z0-9\-_.=]+', caseSensitive: false);
  static final _basic = RegExp(r'Basic\s+[A-Za-z0-9+/=]{8,}', caseSensitive: false);
  static final _jwt = RegExp(r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*');
  static final _urlCredentials = RegExp(r'(https?://)[^@\s/]+:[^@\s/]*@', caseSensitive: false);
  static final _querySecret = RegExp(
    r'(\b(?:password|pass|pwd|token|access_token|refresh_token|key|auth|code|sig|pbk|sid|uuid)=)[^&\s"]+',
    caseSensitive: false,
  );
  static final _jsonSecret = RegExp(
    r'("(?:password|uuid|id|auth|auth_str|psk|token|access_token|refresh_token|private_key|privateKey|publicKey|shortId|short_id)"\s*:\s*)"[^"]*"',
    caseSensitive: false,
  );

  static String redact(String text) {
    // E-mails first, before any other rule rewrites the text around them.
    var out = text.replaceAll(_email, '***@***');
    out = out.replaceAllMapped(_base64Link, (m) => '${m[1]}***');
    out = out.replaceAllMapped(_shareLink, (m) => '${m[1]}***@');
    out = out.replaceAll(_bearer, 'Bearer ***');
    out = out.replaceAll(_basic, 'Basic ***');
    out = out.replaceAll(_jwt, '***');
    out = out.replaceAllMapped(_urlCredentials, (m) => '${m[1]}***@');
    out = out.replaceAllMapped(_querySecret, (m) => '${m[1]}***');
    return out.replaceAllMapped(_jsonSecret, (m) => '${m[1]}"***"');
  }
}
