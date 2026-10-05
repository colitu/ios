import 'package:colitu_vpn/service/xray/setting/routing_rule_state.dart';

class RoutingRuleDnsQueryParams {
  final RoutingRuleState state;
  final List<String> outboundTags;

  RoutingRuleDnsQueryParams(this.state, this.outboundTags);
}
