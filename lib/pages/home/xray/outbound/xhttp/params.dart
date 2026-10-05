import 'package:colitu_vpn/service/xray/outbound/enum.dart';
import 'package:colitu_vpn/service/xray/outbound/xhttp/state.dart';

class OutboundXhttpParams {
  final XhttpMode mode;
  final XhttpExtraState state;

  OutboundXhttpParams(this.mode, this.state);
}
