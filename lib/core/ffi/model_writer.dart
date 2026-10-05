import 'dart:io';

import 'package:colitu_vpn/core/ffi/model.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';

extension RunXrayConfigWriter on RunXrayConfig {
  Future<String> writeToFile() async {
    final data = JsonTool.encoderForFile.convert(toJson());
    final filePath = VpnConstants.coreConfigPath;
    await File(filePath).writeAsString(data);

    return filePath;
  }
}
