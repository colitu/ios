import 'package:colitu_vpn/core/model/xray_json.dart';
import 'package:colitu_vpn/service/xray/setting/enum.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart';

/// The tunnel's core configuration carries no local proxy without a password.
///
/// The inherited setting writer adds an HTTP inbound without accounts
/// ("pingIn", 127.0.0.1 on a free port) and a rule sending it to the proxy.
/// Every app on the phone can reach 127.0.0.1: while the tunnel ran, any of
/// them could find the port, learn the server's exit address through it (VPN
/// detection) or send traffic around the split-tunnel rules. Pings are only
/// measured while the VPN is off (server_latency.dart), so the tunnel needs
/// neither; both are removed before the configuration is written.
abstract final class ColituTunnelInbounds {
  static String get pingTag => RoutingInboundTag.pingIn.name;

  /// [config] without the ping inbound and without rules that only match it.
  static void stripPing(XrayJson config) {
    config.inbounds?.removeWhere((inbound) => inbound.tag == pingTag);
    config.routing?.rules?.removeWhere(
      (rule) =>
          rule.ruleTag == RoutingRuleTag.ping || _onlyPing(rule.inboundTag),
    );
  }

  /// The same for a configuration held as JSON (the raw-config path).
  static void stripPingMap(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is List) {
      inbounds.removeWhere((i) => i is Map && i['tag'] == pingTag);
    }
    final routing = config['routing'];
    final rules = routing is Map ? routing['rules'] : null;
    if (rules is List) {
      rules.removeWhere(
        (r) =>
            r is Map &&
            (r['ruleTag'] == RoutingRuleTag.ping || _onlyPing(r['inboundTag'])),
      );
    }
  }

  /// An HTTP, SOCKS or mixed inbound that takes no user name and password:
  /// no accounts, or (SOCKS, mixed) an `auth` other than "password", with
  /// which Xray ignores the accounts. The tunnel extension drops the same
  /// shape (PacketTunnelProvider.isOpenLocalProxy).
  static bool isOpenLocalProxy(Map<dynamic, dynamic> inbound) {
    final kind = '${inbound['protocol'] ?? ''}'.toLowerCase();
    if (kind != 'http' && kind != 'socks' && kind != 'mixed') return false;
    final settings = inbound['settings'] is Map
        ? inbound['settings'] as Map
        : const {};
    final accounts = settings['accounts'] is List
        ? settings['accounts'] as List
        : settings['users'] is List
        ? settings['users'] as List
        : const [];
    if (accounts.isEmpty) return true;
    if (kind == 'http') return false;
    return '${settings['auth'] ?? ''}'.toLowerCase() != 'password';
  }

  /// Drops every open local proxy (see [isOpenLocalProxy]) from [config]:
  /// every app on the phone can reach 127.0.0.1.
  static void stripOpenProxies(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is List) {
      inbounds.removeWhere((i) => i is Map && isOpenLocalProxy(i));
    }
  }

  static bool _onlyPing(Object? tags) =>
      tags is Iterable &&
      tags.isNotEmpty &&
      tags.every((tag) => tag == pingTag);
}
