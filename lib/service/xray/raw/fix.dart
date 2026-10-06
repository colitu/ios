import 'package:colitu_vpn/colitu/services/colitu_ru_bypass.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/service/tun_setting/state.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:colitu_vpn/service/xray/constants.dart';
import 'package:colitu_vpn/service/xray/setting/enum.dart';
import 'package:colitu_vpn/service/xray/setting/inbounds_state.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';

class XrayRawFix {
  static Future<void> fixConfig(
    Map<String, dynamic> jsonMap,
    TunSettingState tunSettingState,
    XrayPorts ports,
  ) async {
    //fix interface
    if (tunSettingState.shouldFixInterface) {
      final networkInterface = await tunSettingState.networkInterface;
      if (networkInterface == null) {
        return;
      }
      _fixConfigInterface(jsonMap, networkInterface);
      tunSettingState.bindInterface = networkInterface;
    } else {
      _removeConfigInterface(jsonMap);
      tunSettingState.bindInterface = "";
    }

    fixInboundsPort(jsonMap, ports);
    fixLog(jsonMap);
    fixMetrics(jsonMap);
    fixDnsLeakProtection(jsonMap);
    fixRussianIpBypass(jsonMap);
    // After the Russian rule: privacy mode never filters the user's list.
    ColituSplitTunnel.applyTo(jsonMap, ColituSplitTunnel.current);
    if (!tunSettingState.enableIPv6) fixIPv4OnlyDns(jsonMap);
  }

  /// IPv6 is off: the tunnel drops IPv6 packets, so the core's DNS answers
  /// without AAAA records and apps go straight to IPv4 instead of first
  /// trying IPv6 addresses that cannot work. Only an existing `dns` section
  /// is changed; without one the core keeps its defaults.
  static void fixIPv4OnlyDns(Map<String, dynamic> jsonMap) {
    final dns = jsonMap["dns"];
    if (dns is! Map<String, dynamic>) {
      return;
    }
    dns["queryStrategy"] = "UseIPv4";
    final servers = dns["servers"];
    if (servers is! List<dynamic>) {
      return;
    }
    for (final server in servers) {
      if (server is Map<String, dynamic> && server["queryStrategy"] != null) {
        server["queryStrategy"] = "UseIPv4";
      }
    }
  }

  static void fixDnsLeakProtection(Map<String, dynamic> jsonMap) {
    final outbounds = _ensureList(jsonMap, "outbounds");
    final hasProxyOutbound = outbounds.any((item) {
      return item is Map<String, dynamic> &&
          item["tag"] == RoutingOutboundTag.proxy.name;
    });
    if (!hasProxyOutbound) {
      return;
    }

    for (final item in outbounds) {
      if (item is Map<String, dynamic> && item["protocol"] == "dns") {
        final streamSettings = _ensureMap(item, "streamSettings");
        final sockopt = _ensureMap(streamSettings, "sockopt");
        sockopt["dialerProxy"] = RoutingOutboundTag.proxy.name;
      }
    }

    final routing = jsonMap["routing"];
    if (routing is! Map<String, dynamic>) {
      return;
    }
    final rules = routing["rules"];
    if (rules is! List<dynamic>) {
      return;
    }
    for (final rule in rules) {
      if (rule is Map<String, dynamic> && _isDnsRule(rule)) {
        final outboundTag = rule["outboundTag"];
        if (outboundTag == RoutingOutboundTag.direct.name) {
          rule["outboundTag"] = RoutingOutboundTag.proxy.name;
        }
      }
    }
  }

  static void fixRussianIpBypass(Map<String, dynamic> jsonMap) {
    final outbounds = _ensureList(jsonMap, "outbounds");
    final hasDirectOutbound = outbounds.any((item) {
      if (item is! Map<String, dynamic>) {
        return false;
      }
      return item["tag"] == RoutingOutboundTag.direct.name &&
          item["protocol"] == "freedom";
    });
    if (!hasDirectOutbound) {
      outbounds.add(<String, dynamic>{
        "tag": RoutingOutboundTag.direct.name,
        "protocol": "freedom",
      });
    }

    final routing = _ensureMap(jsonMap, "routing");
    routing["domainStrategy"] ??= "IpIfNonMatch";
    final rules = _ensureList(routing, "rules");
    rules.removeWhere((item) {
      return item is Map<String, dynamic> &&
          item["ruleTag"] == RoutingRuleTag.ruBypass;
    });
    if (ColituRuBypass.privacyMode) {
      _removeRussianDirect(rules, outbounds);
    }
    if (!ColituRuBypass.applies) {
      // Privacy mode, or a server in Russia: Russian sites go through the
      // tunnel like everything else.
      return;
    }
    final insertIndex = _dnsRulePrefixLength(rules);
    rules.insert(insertIndex, <String, dynamic>{
      "inboundTag": <String>[RoutingInboundTag.tunIn.name],
      "ip": <String>["geoip:RU"],
      "outboundTag": RoutingOutboundTag.direct.name,
      "ruleTag": RoutingRuleTag.ruBypass,
    });
  }

  /// Privacy mode: Russian matchers leave every rule that sends traffic to a
  /// direct (freedom) outbound, including rules the raw configuration brought.
  static void _removeRussianDirect(
    List<dynamic> rules,
    List<dynamic> outbounds,
  ) {
    final directTags = <Object?>{
      RoutingOutboundTag.direct.name,
      for (final item in outbounds)
        if (item is Map<String, dynamic> && item["protocol"] == "freedom")
          item["tag"],
    };
    rules.removeWhere((item) {
      if (item is! Map<String, dynamic> ||
          !directTags.contains(item["outboundTag"])) {
        return false;
      }
      final domain = item["domain"];
      final ip = item["ip"];
      final lists = ColituRuBypass.withoutRussian<dynamic>(
        domain is List<dynamic> ? domain : null,
        ip is List<dynamic> ? ip : null,
      );
      if (lists == null) return true;
      for (final (key, values) in [
        ("domain", lists.domain),
        ("ip", lists.ip),
      ]) {
        if (values == null) continue;
        if (values.isEmpty) {
          item.remove(key);
        } else {
          item[key] = values;
        }
      }
      return false;
    });
  }

  static void _fixConfigInterface(
    Map<String, dynamic> jsonMap,
    String bindInterface,
  ) {
    final List<dynamic>? outbounds = jsonMap["outbounds"];
    if (outbounds == null) {
      return;
    }
    for (final outbound in outbounds) {
      final Map<String, dynamic>? streamSettings = outbound["streamSettings"];
      if (streamSettings != null) {
        final Map<String, dynamic>? sockopt = streamSettings["sockopt"];
        if (sockopt != null) {
          sockopt["interface"] = bindInterface;
        } else {
          streamSettings["sockopt"] = <String, dynamic>{
            "interface": bindInterface,
          };
        }
      } else {
        final sockopt = <String, dynamic>{"interface": bindInterface};
        outbound["streamSettings"] = <String, dynamic>{"sockopt": sockopt};
      }
    }

    final List<dynamic>? inbounds = jsonMap["inbounds"];
    if (inbounds == null) {
      return;
    }
    for (final inbound in inbounds) {
      if (inbound["tag"] == RoutingInboundTag.tunIn.name &&
          inbound["protocol"] == XrayInboundProtocol.tun.name) {
        final settings = inbound["settings"];
        if (settings != null) {
          settings["autoOutboundsInterface"] = bindInterface;
        } else {
          inbound["settings"] = <String, dynamic>{
            "autoOutboundsInterface": bindInterface,
          };
        }
        break;
      }
    }
  }

  static void _removeConfigInterface(Map<String, dynamic> jsonMap) {
    final List<dynamic>? outbounds = jsonMap["outbounds"];
    if (outbounds == null) {
      return;
    }
    for (final outbound in outbounds) {
      final Map<String, dynamic>? streamSettings = outbound["streamSettings"];
      if (streamSettings != null) {
        final Map<String, dynamic>? sockopt = streamSettings["sockopt"];
        if (sockopt != null) {
          sockopt.remove("interface");
        }
      }
    }
  }

  static void fixInboundsTun(Map<String, dynamic> jsonMap) {
    final List<dynamic>? inbounds = jsonMap["inbounds"];
    if (inbounds == null) {
      return;
    }
    for (final inbound in inbounds) {
      if (inbound["tag"] == RoutingInboundTag.tunIn.name &&
          inbound["protocol"] == XrayInboundProtocol.tun.name) {
        inbounds.remove(inbound);
        return;
      }
    }
  }

  static void fixInboundsPort(Map<String, dynamic> jsonMap, XrayPorts ports) {
    final List<dynamic>? inbounds = jsonMap["inbounds"];
    if (inbounds == null) {
      return;
    }
    for (final inbound in inbounds) {
      if (inbound["tag"] == RoutingInboundTag.pingIn.name &&
          inbound["protocol"] == XrayInboundProtocol.http.name) {
        if (inbound["port"] != null) {
          if (inbound["port"] == VpnConstants.randomPort) {
            inbound["port"] = ports.pingPort;
          } else {
            ports.pingPort = inbound["port"];
          }
        }
      }
    }
  }

  static void fixMetrics(Map<String, dynamic> jsonMap) {
    //remove metrics
    jsonMap.remove("policy");
    jsonMap.remove("metrics");
    jsonMap.remove("stats");
  }

  static void fixLog(Map<String, dynamic> jsonMap) {
    final Map<String, dynamic>? log = jsonMap["log"];
    if (log == null) {
      return;
    }
    log["access"] = XrayStateConstants.accessLogPath;
    log["error"] = XrayStateConstants.errorLogPath;
  }

  static Map<String, dynamic> _ensureMap(
    Map<String, dynamic> parent,
    String key,
  ) {
    final existing = parent[key];
    if (existing is Map<String, dynamic>) {
      return existing;
    }
    final value = <String, dynamic>{};
    parent[key] = value;
    return value;
  }

  static List<dynamic> _ensureList(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    if (existing is List<dynamic>) {
      return existing;
    }
    final value = <dynamic>[];
    parent[key] = value;
    return value;
  }

  static int _dnsRulePrefixLength(List<dynamic> rules) {
    var index = 0;
    while (index < rules.length && _isDnsRule(rules[index])) {
      index++;
    }
    return index;
  }

  static bool _isDnsRule(Object? rule) {
    if (rule is! Map<String, dynamic>) {
      return false;
    }
    final outboundTag = rule["outboundTag"];
    if (outboundTag == RoutingOutboundTag.dnsOut.name) {
      return true;
    }
    final inboundTag = rule["inboundTag"];
    if (inboundTag is List && inboundTag.contains(DNSServerTag.dnsQuery)) {
      return true;
    }
    final port = "${rule["port"] ?? ""}";
    return port == "53" || port == "853";
  }
}
