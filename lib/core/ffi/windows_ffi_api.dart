import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:colitu_vpn/core/ffi/base_ffi_api.dart';
import 'package:colitu_vpn/core/ffi/model.dart';
import 'package:colitu_vpn/core/pigeon/messages.g.dart';
import 'package:colitu_vpn/core/tools/logger.dart';
import 'package:path/path.dart' as p;
import 'package:tuple/tuple.dart';
import 'package:win32/win32.dart';

class WindowsFfiApi extends BaseFfiApi {
  static final WindowsFfiApi _singleton = WindowsFfiApi._internal();

  factory WindowsFfiApi() => _singleton;

  WindowsFfiApi._internal();

  //===================================

  static const _coreExe = "ColituCore.exe";
  static const _startupStabilityWindow = Duration(seconds: 3);
  static const _healthCheckInterval = Duration(seconds: 1);

  var _coreProcess = 0;
  var _coreGeneration = 0;
  var _stopRequested = false;
  Timer? _coreHealthTimer;
  Set<String> _ownedTunAdapterIds = <String>{};

  Future<void> cleanupStaleCore() async {
    if (_coreProcess != 0) return;
    try {
      final result = await Process.run('taskkill', const [
        '/F',
        '/IM',
        _coreExe,
      ], runInShell: false);
      if (result.exitCode == 0) {
        ygLogger('Stopped a stale Colitu core process');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (error) {
      ygLogger('Stale core cleanup skipped: $error');
    }
    await _cleanupOwnedTunAdapters();
    await _cleanupLegacyOrphanedTunAdapter();
  }

  String get _ownedTunMarkerPath => p.join(
    Platform.environment['LOCALAPPDATA'] ??
        p.dirname(Platform.resolvedExecutable),
    'Colitu Secure VPN',
    'owned-tun-adapters.txt',
  );

  String get _legacyTunCleanupMarkerPath => p.join(
    Platform.environment['LOCALAPPDATA'] ??
        p.dirname(Platform.resolvedExecutable),
    'Colitu Secure VPN',
    'legacy-tun-cleanup-v1.complete',
  );

  Future<void> _cleanupLegacyOrphanedTunAdapter() async {
    final marker = File(_legacyTunCleanupMarkerPath);
    if (await marker.exists()) return;
    const script = r'''
$targets = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
  Where-Object { $_.InterfaceDescription -eq 'sing-tun Tunnel' -and $_.Name -eq 'tun0' }
foreach ($target in $targets) {
  $colituAddress = Get-NetIPAddress -InterfaceIndex $target.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object IPAddress -eq '172.19.0.1'
  if ($null -eq $colituAddress) { continue }
  Get-NetRoute -InterfaceIndex $target.ifIndex -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  Disable-NetAdapter -Name $target.Name -Confirm:$false -ErrorAction SilentlyContinue
}
''';
    try {
      final result = await Process.run('powershell.exe', const [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ], runInShell: false);
      if (result.exitCode != 0) {
        ygLogger('Legacy Colitu TUN cleanup exited with ${result.exitCode}');
        return;
      }
      await marker.parent.create(recursive: true);
      await marker.writeAsString('complete', flush: true);
      ygLogger('Legacy Colitu TUN cleanup completed');
    } catch (error) {
      ygLogger('Legacy Colitu TUN cleanup skipped: $error');
    }
  }

  Future<Set<String>> _singTunAdapterIds() async {
    const script = r'''
Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
  Where-Object InterfaceDescription -eq 'sing-tun Tunnel' |
  ForEach-Object { $_.InterfaceGuid.Guid.ToUpperInvariant() }
''';
    try {
      final result = await Process.run('powershell.exe', const [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ], runInShell: false);
      if (result.exitCode != 0) return <String>{};
      return '${result.stdout}'
          .split(RegExp(r'[\r\n]+'))
          .map((value) => value.trim().toUpperCase())
          .where((value) => RegExp(r'^[0-9A-F-]{36}$').hasMatch(value))
          .toSet();
    } catch (error) {
      ygLogger('TUN adapter inventory skipped: $error');
      return <String>{};
    }
  }

  Future<void> _rememberOwnedTunAdapters(Set<String> before) async {
    final after = await _singTunAdapterIds();
    _ownedTunAdapterIds = after.difference(before);
    if (_ownedTunAdapterIds.isEmpty) return;
    try {
      final marker = File(_ownedTunMarkerPath);
      await marker.parent.create(recursive: true);
      await marker.writeAsString(_ownedTunAdapterIds.join('\n'), flush: true);
    } catch (error) {
      ygLogger('Could not persist Colitu TUN ownership: $error');
    }
  }

  Future<void> _cleanupOwnedTunAdapters() async {
    final owned = <String>{..._ownedTunAdapterIds};
    final marker = File(_ownedTunMarkerPath);
    try {
      if (await marker.exists()) {
        owned.addAll(
          (await marker.readAsLines())
              .map((value) => value.trim().toUpperCase())
              .where((value) => RegExp(r'^[0-9A-F-]{36}$').hasMatch(value)),
        );
      }
    } catch (error) {
      ygLogger('Could not read Colitu TUN ownership: $error');
    }
    if (owned.isEmpty) return;
    const script = r'''
$targets = ($env:COLITU_TUN_GUIDS -split ';')
Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
  Where-Object { $targets -contains $_.InterfaceGuid.Guid.ToUpperInvariant() } |
  ForEach-Object {
    Get-NetRoute -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Disable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
  }
''';
    try {
      final result = await Process.run(
        'powershell.exe',
        const [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        environment: {'COLITU_TUN_GUIDS': owned.join(';')},
        runInShell: false,
      );
      if (result.exitCode == 0) {
        ygLogger('Disabled Colitu-owned TUN adapter and routes');
      } else {
        ygLogger('Colitu TUN cleanup exited with ${result.exitCode}');
      }
    } catch (error) {
      ygLogger('Colitu TUN cleanup skipped: $error');
    } finally {
      _ownedTunAdapterIds = <String>{};
      try {
        if (await marker.exists()) await marker.delete();
      } catch (_) {}
    }
  }

  @override
  Future<bool> startCore(String configPath) async {
    _stopCoreMonitor();
    _stopRequested = false;
    final generation = ++_coreGeneration;
    final tunAdaptersBeforeStart = await _singTunAdapterIds();
    final decoded = jsonDecode(await File(configPath).readAsString());
    if (decoded is! Map<String, dynamic>) {
      return false;
    }
    final config = RunXrayConfig.fromJson(decoded);
    if (config.configPath == null ||
        config.configPath!.isEmpty ||
        config.dns == null ||
        config.dns!.isEmpty ||
        config.bindInterface == null ||
        config.bindInterface!.isEmpty) {
      return false;
    }
    final parameters = [
      'run',
      '-dns',
      _quoteArgument(config.dns!),
      '-interface',
      _quoteArgument(config.bindInterface!),
      '-config',
      _quoteArgument(config.configPath!),
    ].join(' ');
    final result = _runCommand(Tuple3("runas", corePath, parameters));
    if (!result.item1 || result.item2 == 0) {
      return false;
    }
    _coreProcess = result.item2;
    ygLogger("Core process started with PID: $_coreProcess");

    await Future.delayed(_startupStabilityWindow);

    if (generation != _coreGeneration || !_isCoreProcessRunning(_coreProcess)) {
      ygLogger('Core failed during the startup stability window');
      _releaseCoreProcess(_coreProcess);
      await _rememberOwnedTunAdapters(tunAdaptersBeforeStart);
      await _cleanupOwnedTunAdapters();
      return false;
    }

    await _rememberOwnedTunAdapters(tunAdaptersBeforeStart);

    final processHandle = _coreProcess;
    _coreHealthTimer = Timer.periodic(
      _healthCheckInterval,
      (_) => unawaited(_checkCoreHealth(processHandle, generation)),
    );
    return true;
  }

  @override
  void stopCore() {
    _stopRequested = true;
    _coreGeneration++;
    _stopCoreMonitor();
    if (_coreProcess == 0) {
      return;
    }

    final processHandle = _coreProcess;
    ygLogger("Stopping core process with handle: $processHandle");

    final terminateResult = TerminateProcess(processHandle, 0);
    if (terminateResult == 0) {
      final errorCode = GetLastError();
      ygLogger("TerminateProcess failed. errorCode=$errorCode");
    } else {
      final waitResult = WaitForSingleObject(processHandle, 3000);
      ygLogger("Core process termination wait result: $waitResult");
    }

    final closeResult = CloseHandle(processHandle);
    if (closeResult == 0) {
      final errorCode = GetLastError();
      ygLogger("CloseHandle failed. errorCode=$errorCode");
    }

    _coreProcess = 0;
  }

  Future<void> _checkCoreHealth(int processHandle, int generation) async {
    if (generation != _coreGeneration ||
        processHandle == 0 ||
        processHandle != _coreProcess) {
      return;
    }
    if (_isCoreProcessRunning(processHandle)) {
      return;
    }

    final unexpectedExit = !_stopRequested;
    ygLogger('Core process exited unexpectedly');
    _stopCoreMonitor();
    _releaseCoreProcess(processHandle);
    await _cleanupOwnedTunAdapters();
    if (unexpectedExit) {
      await updateVpnStatus(VpnStatus.disconnected);
    }
  }

  bool _isCoreProcessRunning(int processHandle) {
    if (processHandle == 0) return false;
    final exitCode = calloc<DWORD>();
    try {
      if (GetExitCodeProcess(processHandle, exitCode) == 0) {
        return false;
      }
      return exitCode.value == STILL_ACTIVE;
    } finally {
      calloc.free(exitCode);
    }
  }

  void _stopCoreMonitor() {
    _coreHealthTimer?.cancel();
    _coreHealthTimer = null;
  }

  void _releaseCoreProcess(int processHandle) {
    if (processHandle == 0) return;
    if (_coreProcess == processHandle) {
      _coreProcess = 0;
    }
    CloseHandle(processHandle);
  }

  String get corePath {
    final bundleDir = p.dirname(Platform.resolvedExecutable);
    final corePath = p.join(bundleDir, "bin", _coreExe);
    return corePath;
  }

  String _quoteArgument(String value) {
    return '"${value.replaceAll('"', '\\"')}"';
  }

  Tuple2<bool, int> _runCommand(Tuple3<String, String, String> command) {
    final lpVerb = command.item1.toNativeUtf16();
    final lpFile = command.item2.toNativeUtf16();
    final lpParameters = command.item3.toNativeUtf16();

    final Pointer<SHELLEXECUTEINFO> info = calloc<SHELLEXECUTEINFO>();
    info.ref.cbSize = sizeOf<SHELLEXECUTEINFO>();
    //SEE_MASK_NOCLOSEPROCESS
    info.ref.fMask = 0x00000040;
    info.ref.lpVerb = lpVerb;
    info.ref.lpFile = lpFile;
    info.ref.lpParameters = lpParameters;
    info.ref.nShow = SW_HIDE;
    final result = ShellExecuteEx(info);
    final process = info.ref.hProcess;
    free(info);
    free(lpVerb);
    free(lpFile);
    free(lpParameters);
    return Tuple2(result == TRUE, process);
  }
}
