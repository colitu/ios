import 'dart:io';

import 'package:colitu_vpn/core/pigeon/model.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';

extension StartVpnRequestWriter on StartVpnRequest {
  Future<void> writeToStartFile() async {
    final data = JsonTool.encoderForFile.convert(toJson());
    final filePath = VpnConstants.startPath;
    await File(filePath).writeAsString(data);
  }
}
