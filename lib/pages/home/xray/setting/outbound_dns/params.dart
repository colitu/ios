import 'package:colitu_vpn/service/xray/setting/outbounds_state.dart';

class OutboundDnsParams {
  final OutboundDnsState state;
  final List<String> outboundTags;

  OutboundDnsParams(this.state, this.outboundTags);
}
