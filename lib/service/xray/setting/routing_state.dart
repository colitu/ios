import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/core/tools/empty.dart';
import 'package:colitu_vpn/service/xray/setting/enum.dart';
import 'package:colitu_vpn/service/xray/setting/routing_rule_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:colitu_vpn/service/xray/standard.dart';

class RoutingState {
  var domainStrategy = RoutingDomainStrategy.ipIfNonMatch;
  var dnsQueryRule = RoutingRuleState.dnsQueryRule;
  final dnsOutRule = RoutingRuleState.dnsOutRule;
  var dnsDoTRule = RoutingRuleState.dnsDoTRule;
  final pingRule = RoutingRuleState.pingRule;
  final ruBypassRule = RoutingRuleState.ruBypassRule;
  var customRules = <RoutingRuleState>[];

  void removeWhitespace() {
    for (final rule in customRules) {
      rule.removeWhitespace();
    }
  }

  void readFromXrayJson(XrayJson xrayJson) {
    if (xrayJson.routing == null) {
      return;
    }
    final routing = xrayJson.routing!;
    if (EmptyTool.checkString(routing.domainStrategy)) {
      final domainStrategy = RoutingDomainStrategy.fromString(
        routing.domainStrategy!,
      );
      if (domainStrategy != null) {
        this.domainStrategy = domainStrategy;
      }
    }
    if (EmptyTool.checkList(routing.rules)) {
      for (final rule in routing.rules!) {
        final ruleState = RoutingRuleState();
        if (EmptyTool.checkString(rule.ruleTag)) {
          if (rule.ruleTag! == RoutingRuleTag.dnsQuery) {
            ruleState.readFromRoutingRule(rule);
            dnsQueryRule.outboundTag = ruleState.outboundTag;
          } else if (rule.ruleTag! == RoutingRuleTag.dnsOut) {
            continue;
          } else if (rule.ruleTag! == RoutingRuleTag.dnsDoT) {
            ruleState.readFromRoutingRule(rule);
            dnsDoTRule.outboundTag = ruleState.outboundTag;
          } else if (rule.ruleTag! == RoutingRuleTag.ping) {
            continue;
          } else if (rule.ruleTag! == RoutingRuleTag.ruBypass) {
            continue;
          } else {
            ruleState.readFromRoutingRule(rule);
            customRules.add(ruleState);
          }
        } else {
          ruleState.readFromRoutingRule(rule);
          customRules.add(ruleState);
        }
      }
    }
  }

  XrayRouting get xrayJson {
    final routing = XrayRoutingStandard.standard;
    routing.domainStrategy = domainStrategy.name;
    final rules = <RoutingRuleState>[
      dnsQueryRule,
      dnsOutRule,
      dnsDoTRule,
      pingRule,
      if (ColituRuBypass.applies) ruBypassRule,
    ];
    if (customRules.isNotEmpty) {
      rules.addAll(customRules);
    }
    var json = rules.map((e) => e.xrayJson).toList();
    if (ColituRuBypass.privacyMode) json = _withoutRussianDirect(json);
    routing.rules = json;
    return routing;
  }

  /// Privacy mode: Russian matchers leave every direct rule, including rules
  /// that came from a stored routing setting.
  static List<XrayRoutingRule> _withoutRussianDirect(
    List<XrayRoutingRule> rules,
  ) {
    final kept = <XrayRoutingRule>[];
    for (final rule in rules) {
      if (rule.outboundTag != RoutingOutboundTag.direct.name) {
        kept.add(rule);
        continue;
      }
      final lists = ColituRuBypass.withoutRussian(rule.domain, rule.ip);
      if (lists == null) continue;
      rule.domain = (lists.domain?.isEmpty ?? true) ? null : lists.domain;
      rule.ip = (lists.ip?.isEmpty ?? true) ? null : lists.ip;
      kept.add(rule);
    }
    return kept;
  }
}
