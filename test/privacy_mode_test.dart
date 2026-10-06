import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/raw/fix.dart';
import 'package:colitu_vpn/service/xray/setting/enum.dart';
import 'package:colitu_vpn/service/xray/setting/routing_rule_state.dart';
import 'package:colitu_vpn/service/xray/setting/routing_state.dart';
import 'package:colitu_vpn/service/xray/setting/simple_state.dart';
import 'package:colitu_vpn/service/xray/setting/simple_state_writer.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Privacy mode: no rule may send Russian destinations to the direct
/// outbound, in either configuration writer.
void main() {
  tearDown(() {
    ColituRuBypass.serverCountry = null;
    ColituRuBypass.privacyMode = false;
  });

  bool russian(Iterable<Object?>? values) =>
      values?.any(ColituRuBypass.isRussianMatcher) ?? false;

  bool uiHasRussianDirect(XrayRouting routing) => (routing.rules ?? []).any(
    (rule) =>
        rule.outboundTag == RoutingOutboundTag.direct.name &&
        (russian(rule.ip) || russian(rule.domain)),
  );

  bool rawHasRussianDirect(Map<String, dynamic> json) =>
      ((json['routing'] as Map)['rules'] as List).any(
        (rule) =>
            rule is Map &&
            rule['outboundTag'] == RoutingOutboundTag.direct.name &&
            (russian(rule['ip'] as List?) || russian(rule['domain'] as List?)),
      );

  void use(String country, {required bool privacy}) {
    ColituRuBypass.serverCountry = country;
    ColituRuBypass.privacyMode = privacy;
  }

  test('the rule applies only outside Russia and without privacy mode', () {
    expect(ColituRuBypass.appliesTo('DE', false), isTrue);
    expect(ColituRuBypass.appliesTo(null, false), isTrue);
    expect(ColituRuBypass.appliesTo(' ru ', false), isFalse);
    expect(ColituRuBypass.appliesTo('DE', true), isFalse);
    expect(ColituRuBypass.appliesTo('RU', true), isFalse);
  });

  group('RoutingState.xrayJson', () {
    test('has the geoip:RU direct rule on a server outside Russia', () {
      use('DE', privacy: false);
      final routing = RoutingState().xrayJson;
      expect(uiHasRussianDirect(routing), isTrue);
      expect(
        routing.rules!.where((r) => r.ruleTag == RoutingRuleTag.ruBypass),
        hasLength(1),
      );
    });

    test('has no Russian direct rule on a server in Russia', () {
      use('RU', privacy: false);
      expect(uiHasRussianDirect(RoutingState().xrayJson), isFalse);
    });

    test('has no Russian direct rule in privacy mode', () {
      use('DE', privacy: true);
      expect(uiHasRussianDirect(RoutingState().xrayJson), isFalse);
    });

    test('privacy mode also clears Russian matchers from stored rules', () {
      use('DE', privacy: true);
      final state = RoutingState();
      state.customRules.add(
        RoutingRuleState()
          ..domain = ['geosite:YANDEX', 'regexp:.ru\$', 'geosite:PRIVATE']
          ..outboundTag = RoutingOutboundTag.direct.name,
      );
      state.customRules.add(
        RoutingRuleState()
          ..ip = ['geoip:RU']
          ..outboundTag = RoutingOutboundTag.direct.name,
      );
      final routing = state.xrayJson;
      expect(uiHasRussianDirect(routing), isFalse);
      // Only the Russian matchers go; the rest of the rule stays.
      expect(
        routing.rules!.where((r) => r.domain?.contains('geosite:PRIVATE') == true),
        hasLength(1),
      );
      // A rule that matched only Russia is gone, not turned into a catch-all.
      expect(
        routing.rules!.where(
          (r) =>
              r.outboundTag == RoutingOutboundTag.direct.name &&
              r.ip == null &&
              r.domain == null,
        ),
        isEmpty,
      );
      // The setting itself is not changed.
      expect(state.customRules.last.ip, ['geoip:RU']);
    });

    test('privacy mode clears the legacy "Russia" simple routing preset', () {
      final simple = XraySettingSimple()..routing.directSet = SimpleCountry.ru;
      use('DE', privacy: false);
      expect(uiHasRussianDirect(simple.xraySettingState.routing.xrayJson), isTrue);
      use('DE', privacy: true);
      expect(uiHasRussianDirect(simple.xraySettingState.routing.xrayJson), isFalse);
    });
  });

  group('XrayRawFix.fixRussianIpBypass', () {
    Map<String, dynamic> config({List<dynamic>? rules}) => <String, dynamic>{
      'outbounds': <dynamic>[
        <String, dynamic>{'tag': 'proxy', 'protocol': 'vless'},
      ],
      'routing': <String, dynamic>{'rules': rules ?? <dynamic>[]},
    };

    test('adds the geoip:RU direct rule on a server outside Russia', () {
      use('DE', privacy: false);
      final json = config();
      XrayRawFix.fixRussianIpBypass(json);
      expect(rawHasRussianDirect(json), isTrue);
    });

    test('adds no Russian direct rule on a server in Russia', () {
      use('RU', privacy: false);
      final json = config();
      XrayRawFix.fixRussianIpBypass(json);
      expect(rawHasRussianDirect(json), isFalse);
    });

    test('adds no Russian direct rule in privacy mode', () {
      use('DE', privacy: true);
      final json = config();
      XrayRawFix.fixRussianIpBypass(json);
      expect(rawHasRussianDirect(json), isFalse);
    });

    test('privacy mode removes Russian direct rules the config brought', () {
      use('DE', privacy: true);
      final json = config(
        rules: <dynamic>[
          <String, dynamic>{
            'ip': <dynamic>['geoip:RU'],
            'outboundTag': 'direct',
          },
          <String, dynamic>{
            'domain': <dynamic>['geosite:category-ru', 'domain:example.org'],
            'outboundTag': 'direct',
          },
          <String, dynamic>{
            'ip': <dynamic>['geoip:RU'],
            'outboundTag': 'proxy',
          },
        ],
      );
      XrayRawFix.fixRussianIpBypass(json);
      expect(rawHasRussianDirect(json), isFalse);
      final rules = (json['routing'] as Map)['rules'] as List;
      expect(rules, hasLength(2));
      expect((rules[0] as Map)['domain'], ['domain:example.org']);
      expect((rules[1] as Map)['outboundTag'], 'proxy');
    });

    test('a stale bypass rule goes when privacy mode is turned on', () {
      use('DE', privacy: false);
      final json = config();
      XrayRawFix.fixRussianIpBypass(json);
      expect(rawHasRussianDirect(json), isTrue);
      use('DE', privacy: true);
      XrayRawFix.fixRussianIpBypass(json);
      expect(rawHasRussianDirect(json), isFalse);
    });
  });
}
