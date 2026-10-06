import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colitu_vpn/service/xray/setting/enum.dart';
import 'package:colitu_vpn/service/xray/setting/state.dart' show DNSServerTag;

/// What split tunneling does with the user's list.
enum SplitTunnelMode {
  /// Everything goes through the VPN (the default).
  off,

  /// The listed sites and addresses go directly, outside the VPN.
  bypass,

  /// Only the listed sites and addresses use the VPN; everything else goes
  /// directly.
  only;

  static SplitTunnelMode parse(Object? value) => switch (value) {
    'bypass' => SplitTunnelMode.bypass,
    'only' => SplitTunnelMode.only,
    _ => SplitTunnelMode.off,
  };
}

/// Why an entry was not added.
enum SplitTunnelEntryError { invalid, duplicate, tooMany }

/// The user's split-tunneling setting: a mode and one list of sites
/// (domains, matched with all their subdomains) and IP addresses / CIDR
/// ranges. iOS lets only managed (MDM) VPN profiles choose apps, so the
/// list holds sites, not apps.
class SplitTunnelSettings {
  const SplitTunnelSettings({
    this.mode = SplitTunnelMode.off,
    this.domains = const [],
    this.ips = const [],
  });

  static const off = SplitTunnelSettings();

  final SplitTunnelMode mode;

  /// Normalised domains ("example.com", "xn--p1ai"), without "domain:".
  final List<String> domains;

  /// Normalised networks ("203.0.113.0/24", "2001:db8::/32").
  final List<String> ips;

  int get count => domains.length + ips.length;

  /// The setting changes the configuration: a mode with at least one entry.
  bool get active => mode != SplitTunnelMode.off && count > 0;

  SplitTunnelSettings copyWith({
    SplitTunnelMode? mode,
    List<String>? domains,
    List<String>? ips,
  }) => SplitTunnelSettings(
    mode: mode ?? this.mode,
    domains: domains ?? this.domains,
    ips: ips ?? this.ips,
  );

  /// Adds a typed entry (a domain, an address or a CIDR range). Returns the
  /// new setting, or the reason it was refused.
  ({SplitTunnelSettings? settings, SplitTunnelEntryError? error}) add(
    String input,
  ) {
    final ip = ColituSplitTunnel.normalizeNetwork(input);
    final domain = ip == null ? ColituSplitTunnel.normalizeDomain(input) : null;
    if (ip == null && domain == null) {
      return (settings: null, error: SplitTunnelEntryError.invalid);
    }
    if ((ip != null && ips.contains(ip)) ||
        (domain != null && domains.contains(domain))) {
      return (settings: null, error: SplitTunnelEntryError.duplicate);
    }
    if (count >= ColituSplitTunnel.maxEntries) {
      return (settings: null, error: SplitTunnelEntryError.tooMany);
    }
    return (
      settings: ip != null
          ? copyWith(ips: [...ips, ip])
          : copyWith(domains: [...domains, domain!]),
      error: null,
    );
  }

  SplitTunnelSettings remove(String entry) => copyWith(
    domains: domains.where((value) => value != entry).toList(),
    ips: ips.where((value) => value != entry).toList(),
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'domains': domains,
    'ips': ips,
  };

  /// Reads a stored setting; entries that no longer validate are dropped.
  factory SplitTunnelSettings.fromJson(Object? json) {
    if (json is! Map) return off;
    List<String> clean(Object? values, String? Function(String) normalize) {
      if (values is! List) return const [];
      final seen = <String>{};
      for (final value in values) {
        if (value is! String) continue;
        final normalized = normalize(value);
        if (normalized != null) seen.add(normalized);
        if (seen.length >= ColituSplitTunnel.maxEntries) break;
      }
      return seen.toList();
    }

    final domains = clean(json['domains'], ColituSplitTunnel.normalizeDomain);
    final ips = clean(json['ips'], ColituSplitTunnel.normalizeNetwork);
    return SplitTunnelSettings(
      mode: SplitTunnelMode.parse(json['mode']),
      domains: domains,
      ips: ips.take(ColituSplitTunnel.maxEntries - domains.length).toList(),
    );
  }

  static SplitTunnelSettings decode(String? text) {
    if (text == null || text.isEmpty) return off;
    try {
      return SplitTunnelSettings.fromJson(jsonDecode(text));
    } catch (_) {
      return off;
    }
  }

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is SplitTunnelSettings &&
      other.mode == mode &&
      _sameList(other.domains, domains) &&
      _sameList(other.ips, ips);

  @override
  int get hashCode => Object.hash(mode, Object.hashAll(domains), Object.hashAll(ips));

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Split tunneling engine. The tunnel carries every packet to Xray through
/// hev-socks5-tunnel; Xray's routing then sends the listed destinations to
/// the `direct` (freedom) outbound or to the proxy. Domains are matched on
/// the name Xray sniffs from the connection (TLS SNI, HTTP Host). Listed
/// IP ranges additionally leave the tunnel at the routing table (excluded
/// routes) in bypass mode, unless the strict kill switch is on.
abstract final class ColituSplitTunnel {
  /// The setting used for the configuration written next; set right before
  /// the core configuration is written, like the privacy mode.
  static SplitTunnelSettings current = SplitTunnelSettings.off;

  static const maxEntries = 200;

  /// Marks the routing rules this class adds (replaced on every write).
  static const ruleTag = 'colituSplit';

  // ── Validation ──────────────────────────────────────────────────────

  /// "https://www.Example.com/path" → "www.example.com", "*.example.com" →
  /// "example.com", "президент.рф" → "xn--d1abbgf6aiiy.xn--p1ai"; null when
  /// it is not a domain name.
  static String? normalizeDomain(String input) {
    var value = input.trim().toLowerCase();
    if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
    final scheme = value.indexOf('://');
    if (scheme >= 0) value = value.substring(scheme + 3);
    value = value.split(RegExp(r'[/?#]')).first;
    if (value.contains('@')) return null;
    final colon = value.lastIndexOf(':');
    if (colon >= 0) {
      if (!RegExp(r'^\d{1,5}$').hasMatch(value.substring(colon + 1))) {
        return null;
      }
      value = value.substring(0, colon);
    }
    while (value.startsWith('*.')) {
      value = value.substring(2);
    }
    if (value.startsWith('.')) value = value.substring(1);
    if (value.endsWith('.')) value = value.substring(0, value.length - 1);
    if (value.isEmpty) return null;
    final labels = <String>[];
    for (final raw in value.split('.')) {
      final label = raw.runes.any((rune) => rune > 0x7F)
          ? 'xn--${punycode(raw)}'
          : raw;
      if (label.isEmpty || label.length > 63) return null;
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(label)) return null;
      if (label.startsWith('-') || label.endsWith('-')) return null;
      labels.add(label);
    }
    if (labels.length < 2) return null;
    // "1.2.3.4" is an address, "example.123" is not a public name.
    if (RegExp(r'^\d+$').hasMatch(labels.last)) return null;
    final domain = labels.join('.');
    return domain.length > 253 ? null : domain;
  }

  /// "203.0.113.7/24" → "203.0.113.0/24", "198.51.100.9" →
  /// "198.51.100.9/32", "2001:DB8::1/32" → "2001:db8::/32"; null for
  /// anything else, for ranges wider than /8 (IPv4) or /16 (IPv6), and for
  /// loopback, multicast and unspecified addresses.
  static String? normalizeNetwork(String input) {
    final value = input.trim();
    if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
    final slash = value.indexOf('/');
    final addressText = slash < 0 ? value : value.substring(0, slash);
    final prefixText = slash < 0 ? null : value.substring(slash + 1);
    final ipv4 = _parseIPv4(addressText);
    if (ipv4 != null) {
      final prefix = prefixText == null ? 32 : int.tryParse(prefixText);
      if (prefix == null || prefix < 8 || prefix > 32) return null;
      if (prefixText != null && !RegExp(r'^\d{1,2}$').hasMatch(prefixText)) {
        return null;
      }
      final masked = _mask(ipv4, prefix);
      final first = masked[0];
      if (first == 0 || first == 127 || first >= 224) return null;
      return '${masked.join('.')}/$prefix';
    }
    if (!addressText.contains(':')) return null;
    final parsed = InternetAddress.tryParse(addressText);
    if (parsed == null || parsed.type != InternetAddressType.IPv6) return null;
    final prefix = prefixText == null ? 128 : int.tryParse(prefixText);
    if (prefix == null || prefix < 16 || prefix > 128) return null;
    if (prefixText != null && !RegExp(r'^\d{1,3}$').hasMatch(prefixText)) {
      return null;
    }
    final masked = _mask(parsed.rawAddress, prefix);
    if (masked[0] == 0xFF) return null; // multicast
    if (masked.every((byte) => byte == 0)) return null; // :: and ::/n
    if (prefix == 128 && masked.take(15).every((b) => b == 0) && masked[15] == 1) {
      return null; // ::1
    }
    final network = InternetAddress.fromRawAddress(
      Uint8List.fromList(masked),
      type: InternetAddressType.IPv6,
    );
    return '${network.address}/$prefix';
  }

  static List<int>? _parseIPv4(String text) {
    final parts = text.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
      final octet = int.parse(part);
      if (octet > 255) return null;
      octets.add(octet);
    }
    return octets;
  }

  static List<int> _mask(List<int> bytes, int prefix) {
    final result = List<int>.from(bytes);
    for (var i = 0; i < result.length; i++) {
      final bits = (prefix - i * 8).clamp(0, 8);
      result[i] &= (0xFF << (8 - bits)) & 0xFF;
    }
    return result;
  }

  /// Whether [network] ("a.b.c.d/n" or "x::/n") contains [address].
  static bool networkContains(String network, String address) {
    final slash = network.indexOf('/');
    if (slash < 0) return false;
    final prefix = int.tryParse(network.substring(slash + 1));
    final base = InternetAddress.tryParse(network.substring(0, slash));
    final target = InternetAddress.tryParse(address);
    if (prefix == null || base == null || target == null) return false;
    if (base.type != target.type) return false;
    final a = _mask(base.rawAddress, prefix);
    final b = _mask(target.rawAddress, prefix);
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── Configuration ───────────────────────────────────────────────────

  /// CIDRs the tunnel excludes from its routes: the bypass list's IP
  /// ranges, except ranges that hold one of [keepInside] (the tunnel's own
  /// DNS servers, which must stay inside or lookups would leak).
  static List<String> excludedRoutes(
    SplitTunnelSettings settings, {
    List<String> keepInside = const [],
  }) {
    if (settings.mode != SplitTunnelMode.bypass) return const [];
    return [
      for (final network in settings.ips)
        if (!keepInside.any((address) => networkContains(network, address)))
          network,
    ];
  }

  /// Writes the split-tunneling rules into a raw Xray configuration.
  /// Earlier rules of this class are removed first; with the setting off
  /// nothing else changes.
  static void applyTo(Map<String, dynamic> config, SplitTunnelSettings settings) {
    final routing = config['routing'];
    if (routing is Map<String, dynamic> && routing['rules'] is List) {
      (routing['rules'] as List).removeWhere(
        (rule) => rule is Map && rule['ruleTag'] == ruleTag,
      );
    }
    if (!settings.active) return;

    final outbounds = _list(config, 'outbounds');
    final directTag = RoutingOutboundTag.direct.name;
    if (!outbounds.any((o) => o is Map && o['tag'] == directTag && o['protocol'] == 'freedom')) {
      outbounds.add(<String, dynamic>{'tag': directTag, 'protocol': 'freedom'});
    }
    final proxyTag = _proxyTag(outbounds);
    final only = settings.mode == SplitTunnelMode.only;
    // Only mode without a proxy outbound would send everything outside the
    // tunnel; leave the configuration as it is then (all through the VPN).
    if (only && proxyTag == null) return;
    final listedTag = only ? proxyTag! : directTag;
    final tunTag = RoutingInboundTag.tunIn.name;

    final newRules = <Map<String, dynamic>>[
      if (settings.domains.isNotEmpty)
        {
          'inboundTag': [tunTag],
          'domain': [for (final d in settings.domains) 'domain:$d'],
          'outboundTag': listedTag,
          'ruleTag': ruleTag,
        },
      if (settings.ips.isNotEmpty)
        {
          'inboundTag': [tunTag],
          'ip': [...settings.ips],
          'outboundTag': listedTag,
          'ruleTag': ruleTag,
        },
      if (only)
        {
          'inboundTag': [tunTag],
          'network': 'tcp,udp',
          'outboundTag': directTag,
          'ruleTag': ruleTag,
        },
    ];

    final Map<String, dynamic> routingMap;
    if (routing is Map<String, dynamic>) {
      routingMap = routing;
    } else {
      routingMap = <String, dynamic>{};
      config['routing'] = routingMap;
    }
    routingMap['domainStrategy'] ??= 'IpIfNonMatch';
    final rules = _list(routingMap, 'rules');
    // After the DNS rules (lookups always go through the VPN), before
    // everything else.
    var index = 0;
    while (index < rules.length && _isDnsRule(rules[index])) {
      index++;
    }
    rules.insertAll(index, newRules);

    if (settings.domains.isNotEmpty) _ensureSniffing(config, tunTag);
  }

  /// Domain rules need the destination name: the tunnel hands Xray IP
  /// addresses, so the TLS/HTTP name is sniffed (for routing only; the
  /// connection keeps its address).
  static void _ensureSniffing(Map<String, dynamic> config, String tunTag) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) return;
    for (final inbound in inbounds) {
      if (inbound is! Map || inbound['tag'] != tunTag) continue;
      final sniffing = inbound['sniffing'];
      if (sniffing is Map && sniffing['enabled'] == true) {
        final dest = [
          ...(sniffing['destOverride'] is List
              ? sniffing['destOverride'] as List
              : const []),
        ];
        for (final protocol in const ['http', 'tls']) {
          if (!dest.contains(protocol)) dest.add(protocol);
        }
        sniffing['destOverride'] = dest;
      } else {
        inbound['sniffing'] = <String, dynamic>{
          'enabled': true,
          'destOverride': ['http', 'tls'],
          'routeOnly': true,
        };
      }
    }
  }

  static List<dynamic> _list(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    if (existing is List) return existing;
    final created = <dynamic>[];
    parent[key] = created;
    return created;
  }

  static String? _proxyTag(List<dynamic> outbounds) {
    final proxy = RoutingOutboundTag.proxy.name;
    if (outbounds.any((o) => o is Map && o['tag'] == proxy)) return proxy;
    for (final outbound in outbounds) {
      if (outbound is! Map) continue;
      final protocol = outbound['protocol'];
      final tag = outbound['tag'];
      if (tag is String && !const ['freedom', 'blackhole', 'dns'].contains(protocol)) {
        return tag;
      }
    }
    return null;
  }

  static bool _isDnsRule(Object? rule) {
    if (rule is! Map) return false;
    if (rule['outboundTag'] == RoutingOutboundTag.dnsOut.name) return true;
    final inboundTag = rule['inboundTag'];
    if (inboundTag is List && inboundTag.contains(DNSServerTag.dnsQuery)) {
      return true;
    }
    final port = '${rule['port'] ?? ''}';
    return port == '53' || port == '853';
  }

  // ── Punycode (RFC 3492) for internationalised domain names ──────────

  static String punycode(String input) {
    const base = 36, tMin = 1, tMax = 26;
    final codePoints = input.runes.toList();
    final output = StringBuffer();
    for (final c in codePoints) {
      if (c < 0x80) output.writeCharCode(c);
    }
    final basic = output.length;
    var handled = basic;
    if (basic > 0) output.write('-');
    var n = 128, delta = 0, bias = 72;
    while (handled < codePoints.length) {
      final m = codePoints.where((c) => c >= n).reduce(math.min);
      delta += (m - n) * (handled + 1);
      n = m;
      for (final c in codePoints) {
        if (c < n) delta++;
        if (c != n) continue;
        var q = delta;
        for (var k = base; ; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          output.writeCharCode(_digit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        output.writeCharCode(_digit(q));
        bias = _adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return output.toString();
  }

  static int _digit(int d) => d < 26 ? 97 + d : 22 + d;

  static int _adapt(int delta, int points, bool first) {
    const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
    var d = first ? delta ~/ damp : delta ~/ 2;
    d += d ~/ points;
    var k = 0;
    while (d > ((base - tMin) * tMax) ~/ 2) {
      d ~/= base - tMin;
      k += base;
    }
    return k + ((base - tMin + 1) * d) ~/ (d + skew);
  }
}
