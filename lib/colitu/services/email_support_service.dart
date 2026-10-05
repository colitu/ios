import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/core/tools/platform.dart';

class EmailSupportService {
  static const _channel = MethodChannel('colitu/mail');
  static const _recipient = 'support@colitu.com';
  static const _subject = 'Colitu Support Request';

  Future<bool> openSupportEmail() async {
    final body = await _supportBody();
    if (AppPlatform.isIOS) {
      try {
        final opened = await _channel.invokeMethod<bool>('composeEmail', {
          'to': _recipient,
          'subject': _subject,
          'body': body,
        });
        if (opened == true) return true;
      } on PlatformException {
        // Fall back to mailto below.
      }
    }
    return _openMailto(body);
  }

  Future<String> _supportBody() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final user = AppSession.instance.currentUser;
    final lines = <String>[
      '',
      '',
      '---',
      'App version: ${packageInfo.version}',
      'Build number: ${packageInfo.buildNumber}',
    ];
    if (AppPlatform.isIOS) {
      try {
        final info = await DeviceInfoPlugin().iosInfo;
        lines.add('iOS version: ${info.systemVersion}');
        lines.add('Device model: ${info.utsname.machine}');
      } catch (_) {
        lines.add('iOS version: unknown');
        lines.add('Device model: unknown');
      }
    }
    if (user != null) {
      if (user.id.isNotEmpty) lines.add('User ID: ${user.id}');
      if (user.email.isNotEmpty) lines.add('Email: ${user.email}');
    }
    return lines.join('\n');
  }

  Future<bool> _openMailto(String body) async {
    final uri = Uri(
      scheme: 'mailto',
      path: _recipient,
      queryParameters: {'subject': _subject, 'body': body},
    );
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
