import 'dart:io';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';

/// Masks the sites a user visited in a connection report before it leaves
/// the device (same rules as the panel's Go version): dial targets, DNS
/// lookups and URL hosts become `<site>` or `<ip>`. Colitu's own servers, the
/// connectivity-check hosts and loopback addresses stay readable.
///
/// Run after `LogRedaction.redact`.
class SiteRedaction {
  const SiteRedaction._();

  static final _dial = RegExp(
    r'\b(tcp|udp):(\[[0-9a-f:.]+\]|[a-z0-9._-]+):(\d{1,5})\b',
    caseSensitive: false,
  );
  static final _lookup = RegExp(
    r'\b(response for|lookup|resolve|resolving|query for|sniffed domain:|got answer:|exchanged|domain:?|domain) '
    r'(\[?[a-z0-9_-]+(?:\.[a-z0-9_-]+)+\]?)\.?',
    caseSensitive: false,
  );

  /// Go's network errors: `dial tcp 1.2.3.4:443`, `read tcp
  /// 10.0.0.2:5000->1.2.3.4:443`, `write udp6 [::1]:5->[2a03::1]:443`.
  static final _goNet = RegExp(
    r'\b(dial|read|write) ((?:tcp|udp)[46]?) (\S+?->)?(\[[0-9a-f:.]+\]|[a-z0-9._-]+):(\d{1,5})\b',
    caseSensitive: false,
  );

  /// sing-box: `outbound connection to host:443`.
  static final _connectionTo = RegExp(
    r'\b(connection to) (\[[0-9a-f:.]+\]|[a-z0-9._-]+):(\d{1,5})\b',
    caseSensitive: false,
  );

  /// JSON log fields: `"addr":"host:443"`.
  static final _jsonAddr = RegExp(
    r'("addr"\s*:\s*")(\[[0-9a-f:.]+\]|[a-z0-9._-]+):(\d{1,5})"',
    caseSensitive: false,
  );

  /// TLS server names: `sni=host`.
  static final _sni = RegExp(r'\b(sni=)(\[[0-9a-f:.]+\]|[a-z0-9._-]+)', caseSensitive: false);

  /// Any other address. Four dotted numbers only (a version such as 5.9.1
  /// has three); IPv6 candidates are checked by parsing, so a time such as
  /// 08:22:01 or a MAC address stays as it is.
  static final _ipv4 = RegExp(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])');
  static final _ipv6 = RegExp(r'(?<![\w.:])[0-9a-f]*:[0-9a-f:]*:[0-9a-f.]*(?![\w:])', caseSensitive: false);

  /// Two-label public suffixes: the registered domain under them has three
  /// labels (`example.co.uk`, not `co.uk`).
  static const _multiLabelSuffixes = {
    'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'com.tr', 'com.ru', 'com.cn',
    'net.cn', 'com.au', 'co.jp', 'com.br',
  };
  static final _url = RegExp(
    r'\b(https?|wss?)://([a-z0-9._-]+|\[[0-9a-f:.]+\])',
    caseSensitive: false,
  );

  static const _fileExtensions = {
    'json', 'jsonl', 'log', 'txt', 'yaml', 'yml', 'dat', 'db',
    'go', 'swift', 'kt', 'cs', 'dart', 'js',
  };

  static const _checkHosts = {
    'www.gstatic.com',
    'connectivitycheck.gstatic.com',
    'captive.apple.com',
    'www.apple.com',
    'ya.ru',
    'www.msftconnecttest.com',
    '8.8.8.8',
    '8.8.4.4',
    '77.88.8.8',
    '208.67.222.222',
    '1.1.1.1',
  };

  /// Host names of the servers the app knows (from the panel's server list,
  /// never hard-coded): the node host and the hosts of its check URLs.
  static Set<String> serverHosts(Iterable<VPNServer> servers) {
    final hosts = <String>{};
    void add(String? value) {
      final text = value?.trim() ?? '';
      if (text.isEmpty) return;
      final host = text.contains('://') ? Uri.tryParse(text)?.host : text;
      if (host != null && host.isNotEmpty) hosts.add(host);
    }

    for (final server in servers) {
      add(server.host);
      add(server.healthCheckUrl);
      add(server.testUrl);
    }
    return hosts;
  }

  static String mask(String text, {Iterable<String> knownHosts = const []}) {
    final known = {
      for (final host in knownHosts)
        if (_normalize(host).isNotEmpty) _normalize(host),
    };
    final knownDomains = {
      for (final host in known)
        if (InternetAddress.tryParse(host) == null) _lastTwo(host),
    };

    String replacement(String host) => InternetAddress.tryParse(_normalize(host)) != null ? '<ip>' : '<site>';

    bool keep(String raw, {bool fileExtensionKept = false}) {
      final host = _normalize(raw);
      if (host.isEmpty) return true;
      if (_checkHosts.contains(host) || known.contains(host)) return true;
      final ip = InternetAddress.tryParse(host);
      if (ip != null) return ip.isLoopback || ip.address == '0.0.0.0' || ip.address == '::';
      if (host == 'localhost') return true;
      if (host == 'colitu.com' || host.endsWith('.colitu.com')) return true;
      if (knownDomains.contains(_lastTwo(host))) return true;
      if (fileExtensionKept) {
        final labels = host.split('.');
        if (labels.length < 2 || _fileExtensions.contains(labels.last)) return true;
      }
      return false;
    }

    return text
        .replaceAllMapped(_dial, (m) {
          final host = m.group(2)!;
          return keep(host) ? m.group(0)! : '${m.group(1)}:${replacement(host)}:${m.group(3)}';
        })
        .replaceAllMapped(_lookup, (m) {
          final host = m.group(2)!;
          return keep(host, fileExtensionKept: true) ? m.group(0)! : '${m.group(1)} ${replacement(host)}';
        })
        .replaceAllMapped(_url, (m) {
          final host = m.group(2)!;
          return keep(host) ? m.group(0)! : '${m.group(1)}://${replacement(host)}';
        })
        .replaceAllMapped(_goNet, (m) {
          final host = m.group(4)!;
          if (keep(host)) return m.group(0)!;
          return '${m.group(1)} ${m.group(2)} ${m.group(3) ?? ''}${replacement(host)}:${m.group(5)}';
        })
        .replaceAllMapped(_connectionTo, (m) {
          final host = m.group(2)!;
          return keep(host) ? m.group(0)! : '${m.group(1)} ${replacement(host)}:${m.group(3)}';
        })
        .replaceAllMapped(_jsonAddr, (m) {
          final host = m.group(2)!;
          return keep(host) ? m.group(0)! : '${m.group(1)}${replacement(host)}:${m.group(3)}"';
        })
        .replaceAllMapped(_sni, (m) {
          final host = m.group(2)!;
          return keep(host) ? m.group(0)! : '${m.group(1)}${replacement(host)}';
        })
        // Last: addresses in any other form.
        .replaceAllMapped(_ipv4, (m) {
          final ip = InternetAddress.tryParse(m.group(0)!);
          return ip == null || keep(ip.address) ? m.group(0)! : '<ip>';
        })
        .replaceAllMapped(_ipv6, (m) {
          final ip = InternetAddress.tryParse(m.group(0)!);
          if (ip == null || ip.type != InternetAddressType.IPv6) return m.group(0)!;
          return keep(ip.address) ? m.group(0)! : '<ip>';
        });
  }

  static String _normalize(String host) {
    var value = host.trim().toLowerCase();
    if (value.startsWith('[') && value.endsWith(']')) value = value.substring(1, value.length - 1);
    if (value.endsWith('.')) value = value.substring(0, value.length - 1);
    return value;
  }

  /// The registered domain of [host]: its last two labels, or three under a
  /// two-label public suffix such as `co.uk`.
  static String _lastTwo(String host) {
    final labels = host.split('.');
    if (labels.length <= 2) return host;
    final take = _multiLabelSuffixes.contains(labels.sublist(labels.length - 2).join('.')) ? 3 : 2;
    return labels.length <= take ? host : labels.sublist(labels.length - take).join('.');
  }
}
