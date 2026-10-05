// Minimal bindings for c/include/libXray.h.
//
// Regenerate with:
//   dart run ffigen
//
// This file is intentionally checked in so CI can compile even when ffigen has
// not been run yet.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

final class NativeLibrary {
  NativeLibrary(ffi.DynamicLibrary dynamicLibrary) : _dylib = dynamicLibrary;

  final ffi.DynamicLibrary _dylib;

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> requestJson)
  CGoInvoke = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> requestJson),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> requestJson)
      >('CGoInvoke');

  late final void Function(ffi.Pointer<ffi.Char> value) CGoFree = _dylib
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Char> value),
        void Function(ffi.Pointer<ffi.Char> value)
      >('CGoFree');

  late final void Function(int fd) CGoSetTunFd = _dylib
      .lookupFunction<ffi.Void Function(ffi.Int32 fd), void Function(int fd)>(
        'CGoSetTunFd',
      );

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoInitDns = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoInitDns');

  late final ffi.Pointer<ffi.Char> Function() CGoResetDns = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(),
        ffi.Pointer<ffi.Char> Function()
      >('CGoResetDns');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoRunXrayFromJSON = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoRunXrayFromJSON');

  late final ffi.Pointer<ffi.Char> Function(int count) CGoGetFreePorts = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Int64 count),
        ffi.Pointer<ffi.Char> Function(int count)
      >('CGoGetFreePorts');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoConvertShareLinksToXrayJson = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoConvertShareLinksToXrayJson');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGOConvertXrayJsonToShareLinks = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGOConvertXrayJsonToShareLinks');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoCountGeoData = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoCountGeoData');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoReadGeoFiles = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoReadGeoFiles');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoPing = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoPing');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoQueryStats = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoQueryStats');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoTestXray = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoTestXray');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
  CGoRunXray = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> base64Text)
      >('CGoRunXray');

  late final ffi.Pointer<ffi.Char> Function() CGoStopXray = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(),
        ffi.Pointer<ffi.Char> Function()
      >('CGoStopXray');

  late final ffi.Pointer<ffi.Char> Function() CGoXrayVersion = _dylib
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(),
        ffi.Pointer<ffi.Char> Function()
      >('CGoXrayVersion');
}
