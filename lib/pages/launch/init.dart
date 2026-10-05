import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/core/tools/file.dart';
import 'package:colitu_vpn/gen/assets.gen.dart';
import 'package:colitu_vpn/pages/main/url.dart';
import 'package:colitu_vpn/service/event_bus/service.dart';
import 'package:colitu_vpn/core/pigeon/constants.dart';
import 'package:path/path.dart' as p;

Future<void> initRouter(BuildContext context) async {
  await _runLaunchStep('Theme', () => _initTheme(context));
  if (context.mounted) {
    await _runLaunchStep('Services', () => _initService(context));
  }
  await _runLaunchStep('System dat', _checkSystemDat);
  if (context.mounted) {
    context.go(RouterPath.colituGate);
  }
}

Future<void> _initTheme(BuildContext context) async {
  final eventBus = context.read<AppEventBus>();
  await eventBus.asyncInitTheme();
}

Future<void> _initService(BuildContext context) async {
  final eventBus = context.read<AppEventBus>();
  await eventBus.asyncInitService(context);
}

Future<void> _runLaunchStep(
  String label,
  Future<void> Function() action,
) async {
  try {
    await action().timeout(const Duration(seconds: 15));
    debugPrint('$label launch step completed');
  } catch (error, stack) {
    debugPrint('$label launch step failed: $error');
    debugPrint('$stack');
  }
}

Future<void> _checkSystemDat() async {
  final datPath = VpnConstants.datDir;
  await FileTool.checkDir(datPath);

  final dstTimestampPath = p.join(datPath, VpnConstants.systemGeoTimestamp);
  final dstTimestampFile = File(dstTimestampPath);
  final exists = await dstTimestampFile.exists();
  if (exists) {
    var dstTimestamp = await dstTimestampFile.readAsString();
    dstTimestamp = dstTimestamp.trim();
    var srcTimestamp = await rootBundle.loadString(Assets.dat.timestamp);
    srcTimestamp = srcTimestamp.trim();
    if (srcTimestamp.compareTo(dstTimestamp) > 0) {
      await FileTool.copyAssets(Assets.dat.values, datPath);
    }
  } else {
    await FileTool.copyAssets(Assets.dat.values, datPath);
  }
}
