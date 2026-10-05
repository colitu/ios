import 'dart:io';

import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/core/network/constants.dart';
import 'package:colitu_vpn/core/pigeon/host_api.dart';
import 'package:colitu_vpn/core/tools/file.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:colitu_vpn/core/tools/logger.dart';
import 'package:colitu_vpn/service/ping/state.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:colitu_vpn/service/xray/constants.dart';

extension XrayJsonWriter on XrayJson {
  Future<String> test() async {
    final configPath = await FileTool.makeCacheFile(ConfigFileType.json);
    await _writeToPath(configPath);
    await FileTool.checkDir(VpnConstants.runDir);

    final res = await AppHostApi().testXray(VpnConstants.datDir, configPath);
    ygLogger(configPath);
    await FileTool.deleteFileIfExists(configPath);

    return res;
  }

  Future<int> ping(PingState pingState, String port) async {
    final configPath = await FileTool.makeCacheFile(ConfigFileType.json);
    await _writeToPath(configPath);

    final res = await AppHostApi().ping(
      VpnConstants.datDir,
      configPath,
      pingState.timeout.toInt(),
      pingState.realUrl,
      "http://${NetConstants.proxyHost}:$port",
    );
    await FileTool.deleteFileIfExists(configPath);

    return res;
  }

  Future<void> _writeToPath(String configPath) async {
    final data = JsonTool.encodeJsonToSortedString(
      toJson(),
      JsonTool.encoderForFile,
    );
    await File(configPath).writeAsString(data);
  }

  Future<String> writeConfig(String runDir) async {
    final configPath = XrayStateConstants.configFilePath;
    await _writeToPath(configPath);
    return configPath;
  }
}
