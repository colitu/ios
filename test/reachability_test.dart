import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/services/adaptive_connect.dart';
import 'package:colitu_vpn/colitu/services/reachability.dart';
import 'package:colitu_vpn/colitu/services/server_groups.dart';
import 'package:flutter_test/flutter_test.dart';

const _all = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'];

/// Ten servers a..j, all answering except those in [dead].
Map<String, int?> _round(Set<String> dead) => {
  for (final id in _all) id: dead.contains(id) ? null : 20,
};

VPNServer _server(
  String id, {
  String country = 'DE',
  bool recommended = false,
}) => VPNServer(
  id: id,
  name: id,
  country: country,
  status: 'online',
  available: true,
  locked: false,
  isPremium: false,
  isFree: true,
  isRecommended: recommended,
  host: '$id.example.test',
  port: 443,
);

void main() {
  group('ServerReachability', () {
    test('one failed round hides nothing, two in a row hide the server', () {
      final r = ServerReachability();
      r.recordRound(_round({'a'}), vpnOff: true);
      expect(r.isUnreachable('a'), isFalse);
      expect(r.hidden(_all), isEmpty);
      r.recordRound(_round({'a'}), vpnOff: true);
      expect(r.isUnreachable('a'), isTrue);
      expect(r.hidden(_all), {'a'});
    });

    test('one success brings the server back', () {
      final r = ServerReachability();
      r.recordRound(_round({'a'}), vpnOff: true);
      r.recordRound(_round({'a'}), vpnOff: true);
      r.recordRound(_round({}), vpnOff: true);
      expect(r.isUnreachable('a'), isFalse);
      expect(r.hidden(_all), isEmpty);
    });

    test('a success in between resets the count', () {
      final r = ServerReachability();
      r.recordRound(_round({'a'}), vpnOff: true);
      r.recordRound(_round({}), vpnOff: true);
      r.recordRound(_round({'a'}), vpnOff: true);
      expect(r.isUnreachable('a'), isFalse);
    });

    test('rounds measured with the VPN on never count', () {
      final r = ServerReachability();
      for (var i = 0; i < 5; i++) {
        r.recordRound(_round({'a'}), vpnOff: false);
      }
      expect(r.isUnreachable('a'), isFalse);
      expect(r.hidden(_all), isEmpty);
    });

    test('every server failing (no network) hides nothing', () {
      final r = ServerReachability();
      r.recordRound(_round({'a'}), vpnOff: true);
      r.recordRound(_round({'a'}), vpnOff: true);
      expect(r.hidden(_all), {'a'});
      r.recordRound(_round(_all.toSet()), vpnOff: true);
      r.recordRound(_round(_all.toSet()), vpnOff: true);
      expect(r.hidden(_all), isEmpty);
      // The failures of a network-wide round count against nobody: once the
      // network is back, a is still hidden by its own two rounds.
      r.recordRound(_round({'a'}), vpnOff: true);
      expect(r.hidden(_all), {'a'});
    });

    test('half of the servers or more failing is the network: no hiding', () {
      final r = ServerReachability();
      final dead = {'a', 'b', 'c', 'd', 'e'};
      r.recordRound(_round(dead), vpnOff: true);
      r.recordRound(_round(dead), vpnOff: true);
      expect(r.hidden(_all), isEmpty);
    });

    test('under half failing hides those servers', () {
      final r = ServerReachability();
      final dead = {'a', 'b', 'c', 'd'};
      r.recordRound(_round(dead), vpnOff: true);
      r.recordRound(_round(dead), vpnOff: true);
      expect(r.hidden(_all), dead);
    });

    test('half or more of the listed servers unreachable: nothing hidden', () {
      final r = ServerReachability();
      final dead = {'a', 'b', 'c', 'd'};
      r.recordRound(_round(dead), vpnOff: true);
      r.recordRound(_round(dead), vpnOff: true);
      // A shorter list in which those four are half of it.
      expect(r.hidden(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']), isEmpty);
    });

    test('connected, connecting and picked servers are never hidden', () {
      final r = ServerReachability();
      final dead = {'a', 'b', 'c'};
      r.recordRound(_round(dead), vpnOff: true);
      r.recordRound(_round(dead), vpnOff: true);
      expect(r.hidden(_all, keep: ['a']), {'b', 'c'});
      expect(r.hidden(_all, keep: ['a', null, 'b', 'c']), isEmpty);
    });

    test('dimmed ignores keep; visible keeps the order', () {
      final r = ServerReachability();
      r.recordRound(_round({'b'}), vpnOff: true);
      r.recordRound(_round({'b'}), vpnOff: true);
      expect(r.dimmed(_all), {'b'});
      final servers = [for (final id in _all.reversed) _server(id)];
      expect(r.visible(servers, (s) => s.id).map((s) => s.id).toList(), [
        for (final id in _all.reversed)
          if (id != 'b') id,
      ]);
      expect(r.visible(servers, (s) => s.id, keep: ['b']).length, 10);
    });

    test('servers without an id (routes) are never judged', () {
      final r = ServerReachability();
      final servers = [_server('a'), _server('b')];
      expect(r.visible(servers, (_) => null).length, 2);
    });
  });

  group('ServerReachability.carryOver', () {
    final now = DateTime(2026, 11, 2, 12);
    ColituPing ping(
      int? ms, {
      Duration age = Duration.zero,
      String net = 'wifi|a',
      bool off = false,
    }) => ColituPing(ms: ms, at: now.subtract(age), network: net, vpnOff: off);

    test('a failed outside reading keeps a VPN-off ping up to 30 minutes', () {
      final previous = ping(40, age: const Duration(minutes: 29), off: true);
      final out = ServerReachability.carryOver(ping(null), previous, now: now);
      expect(identical(out, previous), isTrue);
    });

    test('too old, another network or not a VPN-off reading: the failure', () {
      final fresh = ping(null);
      expect(
        ServerReachability.carryOver(
          fresh,
          ping(40, age: const Duration(minutes: 30), off: true),
          now: now,
        ),
        fresh,
      );
      expect(
        ServerReachability.carryOver(
          fresh,
          ping(40, net: 'cell|b', off: true),
          now: now,
        ),
        fresh,
      );
      expect(ServerReachability.carryOver(fresh, ping(40), now: now), fresh);
      expect(ServerReachability.carryOver(fresh, null, now: now), fresh);
    });

    test('a success, or a failure with the VPN off, is stored as measured', () {
      final ok = ping(25);
      expect(
        ServerReachability.carryOver(ok, ping(40, off: true), now: now),
        ok,
      );
      final offFail = ping(null, off: true);
      expect(
        ServerReachability.carryOver(offFail, ping(40, off: true), now: now),
        offFail,
      );
    });

    test('the VPN-off flag survives storage', () {
      final stored = ColituPing.decodeAll(
        ColituPing.encodeAll({'a': ping(40, off: true), 'b': ping(41)}),
      );
      expect(stored['a']!.vpnOff, isTrue);
      expect(stored['b']!.vpnOff, isFalse);
    });
  });

  group('recommended servers lead their country', () {
    test('stable move to the front inside the country only', () {
      final groups = groupServersByCountry([
        _server('de1'),
        _server('nl1', country: 'NL'),
        _server('de2', recommended: true),
        _server('de3'),
        _server('nl2', country: 'NL', recommended: true),
      ]);
      expect(groups.map((g) => g.key).toList(), ['DE', 'NL']);
      expect(groups[0].servers.map((s) => s.id).toList(), ['de2', 'de1', 'de3']);
      expect(groups[1].servers.map((s) => s.id).toList(), ['nl2', 'nl1']);
    });
  });
}
