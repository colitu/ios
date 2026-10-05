import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/core/tools/platform.dart';

class DiagnosticInfoService {
  Future<String> buildSupportDiagnostics() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final user = AppSession.instance.currentUser;
    final lines = <String>[
      'Diagnostic info',
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
      lines.add('Subscription status: ${user.subscriptionStatus ?? 'unknown'}');
      if (user.id.isNotEmpty) lines.add('User ID: ${user.id}');
      if (user.email.isNotEmpty) lines.add('Email: ${user.email}');
    }

    return lines.join('\n');
  }
}
