import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/api/endpoint_list.dart';
import 'package:colitu_vpn/core/pigeon/flutter_api.dart';
import 'package:colitu_vpn/core/pigeon/host_api.dart';
import 'package:colitu_vpn/core/pigeon/messages.g.dart';
import 'package:colitu_vpn/core/tools/platform.dart';
import 'package:colitu_vpn/pages/main/router.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  final startup = runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _configureErrorLogging();

      await _safeInit('Bridge', _initBridge);
      await _safeInit('Desktop window', _initDesktopWindow);

      runApp(const GoRouteApp());
      // Signed endpoint list refresh, in the background.
      unawaited(EndpointManager.instance.refreshIfDue());
    },
    (error, stack) => _logError('UNCAUGHT ZONE ERROR', error, stack),
  );
  if (startup != null) {
    await startup;
  }
}

Future<void> _initDesktopWindow() async {
  if (AppPlatform.isDesktop) {
    await windowManager.ensureInitialized();

    const windowSize = Size(400, 600);
    // mac store
    // const windowSize = Size(1168, 688);
    WindowOptions windowOptions = WindowOptions(
      size: windowSize,
      minimumSize: windowSize,
      center: true,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
}

Future<void> _initBridge() async {
  BridgeFlutterApi.setUp(AppFlutterApi());
  await AppHostApi().initTunFilesDir();
}

Future<void> _safeInit(String label, Future<void> Function() init) async {
  try {
    await init().timeout(const Duration(seconds: 12));
    debugPrint('$label initialized');
  } catch (error, stack) {
    _logError('$label init failed', error, stack);
  }
}

void _configureErrorLogging() {
  FlutterError.onError = _handleFlutterError;
  PlatformDispatcher.instance.onError = (error, stack) {
    _logError('UNCAUGHT PLATFORM ERROR', error, stack);
    return true;
  };
  ErrorWidget.builder = (details) {
    _handleFlutterError(details);
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Something went wrong. Please restart the app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  };
}

void _handleFlutterError(FlutterErrorDetails details) {
  FlutterError.presentError(details);
  _logError('FLUTTER ERROR', details.exception, details.stack);
}

void _logError(String label, Object error, StackTrace? stack) {
  debugPrint('$label: $error');
  if (stack != null) {
    debugPrint('$stack');
  }
  // Nothing leaves the device: Colitu sends no crash reports or analytics.
}
