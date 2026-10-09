import 'dart:io';

import 'package:colitu_vpn/colitu/services/stall_watch.dart';
import 'package:flutter_test/flutter_test.dart';

class _Interface implements NetworkInterface {
  _Interface(this.name, List<String> addresses)
    : addresses = addresses.map(InternetAddress.new).toList();

  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
  @override
  int get index => 1;
}

void main() {
  final t0 = DateTime(2026, 10, 8, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  /// Runs one check at [seconds]; returns whether the watch asks to switch.
  bool check(
    ColituStallWatch watch,
    int seconds, {
    bool ok = false,
    bool hasNetwork = true,
    int downBytes = 0,
  }) {
    expect(watch.due(at(seconds)), isTrue, reason: 'due at $seconds s');
    final flowing = watch.begin(at(seconds), downBytes);
    return watch.finish(
      ok: ok || flowing,
      hasNetwork: hasNetwork,
      now: at(seconds),
    );
  }

  test('checks every 5 s and switches after 3 failures in a row', () {
    final watch = ColituStallWatch()..reset(t0);
    expect(watch.due(at(4)), isFalse);
    expect(check(watch, 5), isFalse);
    expect(check(watch, 10), isFalse);
    expect(check(watch, 15), isTrue);
    expect(watch.failures, 0);
  });

  test('a successful check resets the count', () {
    final watch = ColituStallWatch()..reset(t0);
    check(watch, 5);
    check(watch, 10);
    expect(check(watch, 15, ok: true), isFalse);
    expect(check(watch, 20), isFalse);
    expect(check(watch, 25), isFalse);
    expect(check(watch, 30), isTrue);
  });

  test('failures without a network do not count', () {
    final watch = ColituStallWatch()..reset(t0);
    check(watch, 5);
    check(watch, 10);
    expect(check(watch, 15, hasNetwork: false), isFalse);
    expect(watch.failures, 0);
  });

  test('received traffic proves the tunnel without a request', () {
    final watch = ColituStallWatch()..reset(t0);
    expect(watch.begin(at(5), 1000), isFalse); // no baseline yet
    watch.finish(ok: false, hasNetwork: true, now: at(5));
    expect(watch.begin(at(10), 1000 + 64 * 1024), isTrue);
    watch.finish(ok: true, hasNetwork: true, now: at(10));
    expect(watch.failures, 0);
  });

  test('no check while one is in flight', () {
    final watch = ColituStallWatch()..reset(t0);
    watch.begin(at(5), 0);
    expect(watch.due(at(20)), isFalse);
    watch.finish(ok: true, hasNetwork: true, now: at(20));
    expect(watch.due(at(25)), isTrue);
  });

  test('at most one automatic switch per 60 s, across sessions', () {
    final watch = ColituStallWatch()..reset(t0);
    check(watch, 5);
    check(watch, 10);
    expect(check(watch, 15), isTrue);
    watch.reset(at(20)); // the new session after the switch
    check(watch, 25);
    check(watch, 30);
    expect(check(watch, 35), isFalse); // 20 s after the last switch
    expect(check(watch, 70), isFalse);
    expect(check(watch, 75), isTrue); // 60 s after the last switch
  });

  test('network detection looks at Wi-Fi and cellular only', () {
    expect(
      ColituStallWatch.hasPhysicalNetwork([
        _Interface('lo0', ['127.0.0.1']),
        _Interface('utun3', ['198.18.0.1']),
      ]),
      isFalse,
    );
    expect(
      ColituStallWatch.hasPhysicalNetwork([
        _Interface('en0', ['fe80::1']),
      ]),
      isFalse,
    );
    expect(
      ColituStallWatch.hasPhysicalNetwork([
        _Interface('utun3', ['198.18.0.1']),
        _Interface('pdp_ip0', ['10.64.12.7']),
      ]),
      isTrue,
    );
    expect(
      ColituStallWatch.hasPhysicalNetwork([
        _Interface('en0', ['192.168.1.20']),
      ]),
      isTrue,
    );
  });
}
