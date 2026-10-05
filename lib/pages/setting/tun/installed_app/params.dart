import 'package:colitu_vpn/core/pigeon/messages.g.dart';

class InstalledAppParams {
  final List<AndroidAppInfo> allApps;
  final Set<String> selections;

  InstalledAppParams(this.allApps, this.selections);
}
