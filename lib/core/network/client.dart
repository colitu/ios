import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/core/network/constants.dart';
import 'package:colitu_vpn/core/network/model.dart';
import 'package:colitu_vpn/core/network/standard.dart';
import 'package:colitu_vpn/core/tools/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';

class NetClient {
  static final NetClient _singleton = NetClient._internal();

  factory NetClient() => _singleton;

  NetClient._internal() {
    _proxyClient.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) => _proxy;
        return client;
      },
    );
  }

  //========================
  final _proxyClient = Dio(
    BaseOptions(
      connectTimeout: Duration(seconds: 10),
      receiveTimeout: Duration(seconds: 10),
    ),
  );
  final _downloadClient = Dio(
    BaseOptions(connectTimeout: Duration(seconds: 10)),
  );

  String _proxyPort = "${NetConstants.defaultPingPort}";

  String get _proxy {
    return "PROXY ${NetConstants.proxyHost}:$_proxyPort";
  }

  Future<void> asyncInit() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final userAgent =
        '${AppEnvironment.appName}/${packageInfo.version} (${packageInfo.packageName}; build:${packageInfo.buildNumber}; ${Platform.operatingSystem})';
    final headers = <String, String>{'User-Agent': userAgent};
    _downloadClient.options.headers = headers;
  }

  Future<GeoLocation> connectivityTest(String port, String url) async {
    _proxyPort = port;
    var location = GeoLocationStandard.standard;
    final retryCount = 3;
    for (var i = 0; i < retryCount; i++) {
      try {
        final start = DateTime.now().millisecondsSinceEpoch;
        location = await _geoLocation();
        if (location.ipAddress != null) {
          final end = DateTime.now().millisecondsSinceEpoch;
          location.delay = end - start;
          break;
        } else {
          await Future.delayed(Duration(seconds: 2));
        }
      } catch (e) {
        ygLogger("$e");
      }
    }
    return location;
  }

  Future<String?> publicIp() async {
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 6),
        headers: const {'Connection': 'close', 'Cache-Control': 'no-cache'},
      ),
    );
    try {
      try {
        final response = await client.get<Map<String, dynamic>>(
          _geoIPUrl,
          options: Options(receiveTimeout: const Duration(seconds: 6)),
        );
        final value = '${response.data?['ip_address'] ?? ''}'.trim();
        if (InternetAddress.tryParse(value) != null) return value;
      } catch (error) {
        ygLogger('Primary public IP check failed: $error');
      }

      try {
        final response = await client.get<String>(
          'https://api.ipify.org',
          options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 6),
          ),
        );
        final value = (response.data ?? '').trim();
        if (InternetAddress.tryParse(value) != null) return value;
      } catch (error) {
        ygLogger('Fallback public IP check failed: $error');
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Generic connectivity endpoints (never the Colitu API): each answers
  /// 204 or a short 200 from a nearby edge.
  static const trafficCheckUrls = [
    'https://cp.cloudflare.com/generate_204',
    'https://www.gstatic.com/generate_204',
    'http://www.msftconnecttest.com/connecttest.txt',
  ];

  /// True as soon as one of [trafficCheckUrls] answers 2xx. Used through the
  /// tunnel right after it comes up and while it runs: the requests go out in
  /// parallel and the first success decides. A fresh client avoids reusing
  /// sockets that were opened before the tunnel.
  ///
  /// [proxy] (a `findProxy` answer) sends the requests through a local
  /// proxy instead, such as the core's warm-spare check inbound.
  Future<bool> trafficCheck({
    Duration timeout = const Duration(seconds: 3),
    String? proxy,
  }) async {
    final client = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        headers: const {'Connection': 'close', 'Cache-Control': 'no-cache'},
      ),
    );
    if (proxy != null) {
      client.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = (_) => proxy,
      );
    }
    final done = Completer<bool>();
    var pending = trafficCheckUrls.length;
    Future<void> probe(String url) async {
      try {
        final response = await client.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (_) => true,
          ),
        );
        final code = response.statusCode ?? 0;
        if (code >= 200 && code < 300 && !done.isCompleted) {
          done.complete(true);
        }
      } catch (_) {
        // This endpoint did not answer; another one may.
      } finally {
        pending--;
        if (pending == 0 && !done.isCompleted) done.complete(false);
      }
    }

    for (final url in trafficCheckUrls) {
      unawaited(probe(url));
    }
    try {
      return await done.future.timeout(
        timeout + const Duration(milliseconds: 500),
        onTimeout: () => false,
      );
    } finally {
      client.close(force: true);
    }
  }

  final _geoIPUrl = "https://ip-check-perf.radar.cloudflare.com/";

  Future<GeoLocation> _geoLocation() async {
    var location = GeoLocationStandard.standard;
    try {
      final res = await _proxyClient.get<Map<String, dynamic>>(_geoIPUrl);
      if (res.statusCode == 200 && res.data != null) {
        final location = GeoLocation.fromJson(res.data!);
        return location;
      }
    } catch (e) {
      ygLogger("$e");
    }
    return location;
  }

  Future<String?> getText(String url) async {
    try {
      final res = await _downloadClient.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      return res.data;
    } catch (e) {
      ygLogger("getText request failed");
      return null;
    }
  }

  Future<bool> downloadFile(String url, String savePath) async {
    try {
      await _downloadClient.download(url, savePath);
      return true;
    } catch (e) {
      ygLogger("downloadFile request failed");
      return false;
    }
  }
}
