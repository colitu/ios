import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:isolate_manager/isolate_manager.dart';
import 'package:colitu_vpn/core/ffi/generated_bindings.dart';
import 'package:colitu_vpn/core/ffi/model_reader.dart';
import 'package:colitu_vpn/core/ffi/model_writer.dart';
import 'package:colitu_vpn/core/pigeon/flutter_api.dart';
import 'package:colitu_vpn/core/pigeon/messages.g.dart';
import 'package:colitu_vpn/core/pigeon/model_reader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:colitu_vpn/core/tools/platform.dart';

abstract class BaseFfiApi {
  Future<String> getTunFilesDir() async {
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  var _vpnStatus = VpnStatus.disconnected;

  Future<void> readVpnStatus() async {
    await AppFlutterApi().vpnStatusChanged(_vpnStatus);
  }

  Future<void> updateVpnStatus(VpnStatus status) async {
    _vpnStatus = status;
    await AppFlutterApi().vpnStatusChanged(_vpnStatus);
  }

  Future<void> startVpn() async {
    await updateVpnStatus(VpnStatus.connecting);

    final request = await StartVpnRequestReader.readFromStartFile();
    final coreConfig = RunXrayConfigReader.readFromStartVpnRequest(request);
    final configPath = await coreConfig.writeToFile();

    var res = await startCore(configPath);
    if (!res) {
      await stopVpn();
      return;
    }
    await updateVpnStatus(VpnStatus.connected);
  }

  Future<bool> startCore(String configPath) async {
    return true;
  }

  void stopCore() {}

  Future<void> stopVpn() async {
    await updateVpnStatus(VpnStatus.disconnecting);
    stopCore();
    await Future.delayed(Duration(seconds: 1));
    await updateVpnStatus(VpnStatus.disconnected);
  }

  final _sharedIsolate = IsolateManager.createShared(concurrent: 1);
  void stopSharedIsolate() {
    _sharedIsolate.stop();
  }

  Future<String> initDns(String base64Text) async {
    return _sharedIsolate.compute(_cgoInitDns, base64Text);
  }

  Future<String> resetDns() async {
    return _sharedIsolate.compute(_cgoResetDns, 0);
  }

  Future<String> getFreePorts(int num) async {
    return _sharedIsolate.compute(_cgoGetFreePorts, num);
  }

  Future<String> convertShareLinksToXrayJson(String base64Text) async {
    return _sharedIsolate.compute(_cgoConvertShareLinksToXrayJson, base64Text);
  }

  Future<String> convertXrayJsonToShareLinks(String base64Text) async {
    return _sharedIsolate.compute(_cgoConvertXrayJsonToShareLinks, base64Text);
  }

  Future<String> countGeoData(String base64Text) async {
    return _sharedIsolate.compute(_cgoCountGeoData, base64Text);
  }

  Future<String> readGeoFiles(String base64Text) async {
    return _sharedIsolate.compute(_cgoReadGeoFiles, base64Text);
  }

  Future<String> queryStats(String base64Text) async {
    return _sharedIsolate.compute(_cgoQueryStats, base64Text);
  }

  Future<String> ping(String base64Text) async {
    return _sharedIsolate.compute(_cgoPing, base64Text);
  }

  Future<String> testXray(String base64Text) async {
    return _sharedIsolate.compute(_cgoTestXray, base64Text);
  }

  Future<String> runXray(String base64Text) async {
    return _sharedIsolate.compute(_cgoRunXray, base64Text);
  }

  Future<String> stopXray() async {
    return _sharedIsolate.compute(_cgoStopXray, 0);
  }

  Future<String> xrayVersion() async {
    return _sharedIsolate.compute(_cgoXrayVersion, 0);
  }
}

class _CoreLib {
  late final NativeLibrary _lib;

  static final _CoreLib _singleton = _CoreLib._internal();

  factory _CoreLib() => _singleton;

  _CoreLib._internal() {
    var libName = "";
    if (AppPlatform.isLinux) {
      libName = "libXray.so";
    } else if (AppPlatform.isWindows) {
      libName = "libXray.dll";
    }
    final lib = DynamicLibrary.open(libName);
    _lib = NativeLibrary(lib);
  }
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoInitDns(String base64Text) {
  return _unsupportedInvoke('initDns');
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoResetDns(int _) {
  return _unsupportedInvoke('resetDns');
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoGetFreePorts(int num) {
  return _invoke('getFreePorts', {'count': num});
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoConvertShareLinksToXrayJson(String base64Text) {
  return _invoke('convertShareLinksToXrayJson', {
    'text': utf8.decode(base64Decode(base64Text)),
  });
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoConvertXrayJsonToShareLinks(String base64Text) {
  final config = _decodeBase64Json(base64Text);
  return _invoke('convertXrayJsonToShareLinks', {
    'xrayJson': jsonEncode(config),
  });
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoCountGeoData(String base64Text) {
  return _invoke('countGeoData', _decodeBase64Json(base64Text));
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoReadGeoFiles(String base64Text) {
  return _unsupportedInvoke('readGeoFiles');
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoPing(String base64Text) {
  final legacy = _decodeBase64Json(base64Text);
  return _invoke('pingBatch', {
    'configs': [
      {'xrayJson': _readXrayJson(legacy)},
    ],
    'timeout': legacy['timeout'],
    'url': legacy['url'],
  });
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoQueryStats(String base64Text) {
  return _unsupportedInvoke('queryStats');
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoTestXray(String base64Text) {
  final legacy = _decodeBase64Json(base64Text);
  return _invoke('testXray', {'xrayJson': _readXrayJson(legacy)});
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoRunXray(String base64Text) {
  final legacy = _decodeBase64Json(base64Text);
  return _invoke('runXray', {'xrayJson': _readXrayJson(legacy)});
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoStopXray(int _) {
  return _invoke('stopXray', const <String, dynamic>{});
}

@pragma('vm:entry-point')
@isolateManagerSharedWorker
String _cgoXrayVersion(int _) {
  return _invoke('xrayVersion', const <String, dynamic>{});
}

Pointer<Char> _convertStringToPointer(String text) {
  final pointer = text.toNativeUtf8().cast<Char>();
  return pointer;
}

Map<String, dynamic> _decodeBase64Json(String value) {
  final decoded = jsonDecode(utf8.decode(base64Decode(value)));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid native request payload');
  }
  return decoded;
}

String _readXrayJson(Map<String, dynamic> legacy) {
  final configPath = legacy['configPath'];
  if (configPath is! String || configPath.isEmpty) {
    throw const FormatException('Xray config path is missing');
  }
  final decoded = jsonDecode(File(configPath).readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid Xray configuration');
  }
  final datDir = legacy['datDir'];
  if (datDir is String && datDir.isNotEmpty) {
    final currentEnv = decoded['env'];
    final env = currentEnv is Map
        ? Map<String, dynamic>.from(currentEnv)
        : <String, dynamic>{};
    env['xray.location.asset'] = datDir;
    decoded['env'] = env;
  }
  return jsonEncode(decoded);
}

String _invoke(String method, Map<String, dynamic> payload) {
  var responsePointer = nullptr.cast<Char>();
  try {
    final request = jsonEncode({
      'apiVersion': 3,
      'method': method,
      'payload': payload,
    });
    final requestPointer = _convertStringToPointer(request);
    try {
      responsePointer = _CoreLib()._lib.CGoInvoke(requestPointer);
    } finally {
      calloc.free(requestPointer);
    }
    if (responsePointer == nullptr) {
      throw StateError('libXray returned a null response');
    }
    final raw = responsePointer.cast<Utf8>().toDartString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid libXray response');
    }
    _normalizeInvokeResponse(method, decoded);
    return base64Encode(utf8.encode(jsonEncode(decoded)));
  } catch (error) {
    return base64Encode(
      utf8.encode(
        jsonEncode({'success': false, 'data': null, 'error': '$error'}),
      ),
    );
  } finally {
    if (responsePointer != nullptr) {
      _CoreLib()._lib.CGoFree(responsePointer);
    }
  }
}

void _normalizeInvokeResponse(String method, Map<String, dynamic> response) {
  if (response['success'] != true) return;
  final data = response['data'];
  if (method == 'xrayVersion' && data is Map<String, dynamic>) {
    response['data'] = data['version'];
  } else if (method == 'convertXrayJsonToShareLinks' && data is Map) {
    response['data'] = data['links'];
  } else if (method == 'pingBatch' && data is Map) {
    final results = data['results'];
    if (results is List && results.isNotEmpty && results.first is Map) {
      response['data'] = (results.first as Map)['delay'];
    }
  }
}

String _unsupportedInvoke(String method) {
  return base64Encode(
    utf8.encode(
      jsonEncode({
        'success': false,
        'data': null,
        'error': '$method is unavailable in this desktop libXray build',
      }),
    ),
  );
}
