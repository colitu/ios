import 'package:colitu_vpn/core/ffi/model.dart';
import 'package:colitu_vpn/core/pigeon/model.dart';
import 'package:colitu_vpn/core/tools/empty.dart';
import 'package:colitu_vpn/core/tools/json.dart';

extension RunXrayConfigReader on RunXrayConfig {
  static RunXrayConfig readFromStartVpnRequest(StartVpnRequest request) {
    if (!EmptyTool.checkString(request.coreBase64Text)) {
      return RunXrayConfig(null, null, null, null, null, null);
    }
    if (!EmptyTool.checkString(request.tun?.tunDnsIPv4)) {
      return RunXrayConfig(null, null, null, null, null, null);
    }
    final dns = "${request.tun!.tunDnsIPv4}:53";
    final runXrayRquestMap = JsonTool.decodeBase64ToJson(
      request.coreBase64Text!,
    );
    final runXrayRequest = RunXrayRequest.fromJson(runXrayRquestMap);
    final config = RunXrayConfig(
      request.tun?.tunName,
      request.tun?.tunPriority,
      dns,
      request.tun?.bindInterface,
      runXrayRequest.datDir,
      runXrayRequest.configPath,
    );
    return config;
  }
}
