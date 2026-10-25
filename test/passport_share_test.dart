import 'dart:io';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_client.dart';
import 'package:colitu_vpn/colitu/passport/passport_store.dart';
import 'package:colitu_vpn/colitu/services/app_event_log.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// "Share stamp": the card is rendered, written, handed to the share sheet
/// with a real anchor rect and kept until the next share; a failure shows a
/// message and lands in the connection report's app log.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory temp;
  late List<MethodCall> calls;
  Object? Function(MethodCall call)? answer;

  setUp(() async {
    await ColituLoc.I.setLanguage('en', persist: false);
    temp = await Directory.systemTemp.createTemp('passport-share');
    passportShareDir = () async => Directory(p.join(temp.path, 'share'));
    AppEventLog.dirOverride = p.join(temp.path, 'run');
    PassportClient.I = PassportClient(api: _NoApi(), deviceId: () async => 'd');
    ColituPassport.I = ColituPassport(store: PassportStore())
      ..store.setInt('t_SE', 1)
      ..store.setInt('p_SE', 13);
    calls = [];
    answer = (_) => 'com.apple.UIKit.activity.SaveToCameraRoll';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final result = answer!(call);
      if (result is Exception) throw result;
      return result;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    AppEventLog.dirOverride = null;
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // Windows may still hold a file a moment longer; the temp folder is temporary.
    }
  });

  Future<bool?> tapShare(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (button) => ElevatedButton(
                onPressed: () async {
                  result = await sharePassport(button, stamp: ColituPassport.stampOf('SE'), premium: false);
                },
                child: const Text('Share stamp'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Share stamp'));
    // Rendering and file writes are real async work: let real time pass and
    // run what it completed.
    for (var i = 0; i < 300 && result == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    return result;
  }

  testWidgets('the card reaches the share sheet with an anchor and stays until the next share', (tester) async {
    expect(await tapShare(tester), isTrue);
    expect(calls, hasLength(1));
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    final paths = (args['paths'] as List).cast<String>();
    expect(args['mimeTypes'], ['image/png']);
    expect(args['text'], contains('Sweden'));
    expect(args['originWidth'] as double, greaterThan(0));
    expect(args['originHeight'] as double, greaterThan(0));
    // Kept after the sheet closed: a share extension may still read it.
    final file = File(paths.single);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync().take(4), [0x89, 0x50, 0x4E, 0x47]);

    // The next share starts with an empty folder.
    File(p.join(file.parent.path, 'old.png')).writeAsStringSync('x');
    expect(await tapShare(tester), isTrue);
    expect(file.parent.listSync().map((e) => p.basename(e.path)), ['colitu-passport-se.png']);
  });

  testWidgets('a failing share sheet shows a message and is logged', (tester) async {
    answer = (_) => PlatformException(code: 'error', message: 'sharePositionOrigin: argument must be set');
    expect(await tapShare(tester), isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(ColituLoc.I['passport.shareFailed']), findsOneWidget);
    final file = File(p.join(AppEventLog.dirOverride!, AppEventLog.fileName));
    var log = '';
    for (var i = 0; i < 100 && !log.contains('\n'); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (file.existsSync()) log = file.readAsStringSync();
    }
    expect(log, contains('passport_share_failed step=share'));
    expect(log, contains('sharePositionOrigin'));
  });

  test('without a laid-out button the anchor is a small rect in the middle of the screen', () {
    final origin = shareOrigin(_DetachedContext());
    expect(origin.isEmpty, isFalse);
    expect(origin.width, 2);
  });
}

class _DetachedContext extends Fake implements BuildContext {
  @override
  RenderObject? findRenderObject() => null;
}

class _NoApi extends Fake implements PassportApi {
  @override
  Future<void> share() async {}
}
