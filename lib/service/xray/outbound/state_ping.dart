import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/service/ping/state.dart';
import 'package:colitu_vpn/service/xray/json_writer.dart';
import 'package:colitu_vpn/service/xray/outbound/state.dart';
import 'package:colitu_vpn/service/xray/outbound/state_writer.dart';
import 'package:colitu_vpn/service/xray/setting/inbounds_state.dart';
import 'package:colitu_vpn/service/xray/standard.dart';

extension OutboundStatePing on OutboundState {
  Future<int> ping(PingState pingState) async {
    final ports = await XrayPorts.getPorts();
    if (ports == null) {
      return PingDelayConstants.unknown;
    }
    final pingInbound = InboundPingState();
    pingInbound.port = ports.pingPort;

    final xrayJson = XrayJsonStandard.standard;
    xrayJson.outbounds = [this.xrayJson];
    xrayJson.inbounds = [pingInbound.xrayJson];
    final res = await xrayJson.ping(pingState, ports.pingPort);
    return res;
  }
}
