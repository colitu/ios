import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_share.dart';

/// Passport Duel (Android PassportP3.kt): show my QR to a friend, or scan
/// theirs and compare side by side; friends are kept on this device.
/// Nothing goes to a server.
Future<void> showPassportDuel(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (_) => const PassportDuelDialog(),
  );
}

class PassportDuelDialog extends StatefulWidget {
  const PassportDuelDialog({super.key, this.initialMode = 0});

  /// 0 my QR, 1 scan, 2 friends.
  final int initialMode;

  @override
  State<PassportDuelDialog> createState() => _PassportDuelDialogState();
}

class _PassportDuelDialogState extends State<PassportDuelDialog> {
  late var _mode = widget.initialMode;
  DuelPassport? _friend;
  var _bad = false;

  void _onScan(BarcodeCapture capture) {
    if (_friend != null) return;
    final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (value == null) return;
    final parsed = PassportSocial.parseDuel(value);
    if (parsed == null) {
      if (!_bad) setState(() => _bad = true);
      return;
    }
    ColituPassport.I.social.addFriend(parsed.toFriend(ColituPassport.I.now().millisecondsSinceEpoch));
    setState(() => _friend = parsed);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ColituPassport.I, ColituLoc.I]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final loc = ColituLoc.I;
    final them = _friend;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 720),
        child: Container(
          decoration: BoxDecoration(
            color: ColituColors.surface,
            borderRadius: BorderRadius.circular(ColituRadius.lg),
            border: Border.all(color: ColituColors.lineStrong),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(loc['passport.duel.title'], style: ColituText.h2),
                const SizedBox(height: 4),
                Text(loc['passport.duel.sub'], textAlign: TextAlign.center, style: ColituText.small),
                const SizedBox(height: 14),
                if (them != null) ...[
                  DuelCompare(them: them),
                  const SizedBox(height: 14),
                  ColituButton.secondary(
                    label: loc['passport.duel.again'],
                    onPressed: () => setState(() {
                      _friend = null;
                      _bad = false;
                      _mode = 1;
                    }),
                  ),
                ] else ...[
                  ColituSegment<int>(
                    values: const [0, 1, 2],
                    selected: _mode,
                    onChanged: (m) => setState(() => _mode = m),
                    labelOf: (m) => [loc['passport.duel.mine'], loc['passport.duel.scan'], loc['passport.friends']][m],
                  ),
                  const SizedBox(height: 16),
                  if (_mode == 2)
                    _FriendsList(onOpen: (f) => setState(() => _friend = DuelPassport.fromFriend(f)))
                  else if (_mode == 0) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                      child: PassportQr(data: ColituPassport.I.social.myDuelLink(), size: 220),
                    ),
                    const SizedBox(height: 10),
                    Text(identityLine(), textAlign: TextAlign.center, style: ColituText.small.copyWith(color: ColituColors.lilac)),
                  ] else ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: 260,
                        height: 260,
                        child: MobileScanner(
                          onDetect: _onScan,
                          errorBuilder: (context, error) => Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(loc['passport.duel.camera'], textAlign: TextAlign.center, style: ColituText.small),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _bad ? loc['passport.duel.notPassport'] : loc['passport.duel.point'],
                      textAlign: TextAlign.center,
                      style: ColituText.small,
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                ColituButton.secondary(
                  label: loc['passport.close'],
                  height: 48,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _levelLabel(int n) => switch (n) {
  0 => '—',
  5 => ColituLoc.I['passport.masteredShort'],
  _ => levelName(StampLevel.values[n - 1]),
};

Color _levelTint(int n) => n == 0 ? ColituColors.dim : levelColor(StampLevel.values[(n - 1).clamp(0, 3)]);

/// Me and a friend side by side: counts, then every stamp either of us has.
class DuelCompare extends StatelessWidget {
  const DuelCompare({super.key, required this.them});

  final DuelPassport them;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final theirName = them.nick.trim().isEmpty ? loc.format('passport.id.collector', {'n': them.collector}) : them.nick;
    final theirTitle = PassportAchievement.values.where((a) => a.id == them.title).firstOrNull?.title;
    final rows = ColituPassport.allStamps.where((s) => p.social.myLevel(s.code) > 0 || (them.levels[s.code] ?? 0) > 0);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Column(
              children: [
                Text(loc['passport.duel.you'], style: ColituText.small),
                Text('${p.count}/10', style: ColituText.display.copyWith(fontSize: 34, color: ColituColors.lilac)),
              ],
            ),
            Flexible(
              child: Column(
                children: [
                  Text(theirName, maxLines: 1, overflow: TextOverflow.ellipsis, style: ColituText.small),
                  Text('${them.count(ColituPassport.stamps)}/10', style: ColituText.display.copyWith(fontSize: 34)),
                  if (theirTitle != null) Text(theirTitle, style: ColituText.small.copyWith(color: ColituColors.lilac)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final s in rows)
          Builder(
            builder: (context) {
              final a = p.social.myLevel(s.code);
              final b = them.levels[s.code] ?? 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    ColituFlag(s.code, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        loc.countryName(s.code),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ColituText.small.copyWith(color: ColituColors.text),
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: Text(
                        _levelLabel(a),
                        textAlign: TextAlign.center,
                        style: ColituText.small.copyWith(
                          color: _levelTint(a),
                          fontWeight: a > b ? FontWeight.w700 : null,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: Text(
                        _levelLabel(b),
                        textAlign: TextAlign.center,
                        style: ColituText.small.copyWith(
                          color: _levelTint(b),
                          fontWeight: b > a ? FontWeight.w700 : null,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Friends scanned with the passport QR, kept on this device. With the
/// ranking on, you stand among them by Origin stamps, then by levels.
class _FriendsList extends StatelessWidget {
  const _FriendsList({required this.onOpen});

  final ValueChanged<PassportFriend> onOpen;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final social = p.social;
    final friends = social.friends;
    if (friends.isEmpty) {
      return Text(loc['passport.friends.empty'], textAlign: TextAlign.center, style: ColituText.small);
    }
    final rows = rankFriends(p, friends, ranking: social.showRanking, myName: loc['passport.duel.you']);
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(loc['passport.friends.ranking'], style: ColituText.label)),
            CupertinoSwitch(
              value: social.showRanking,
              activeTrackColor: ColituColors.violet,
              onChanged: social.updateRanking,
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < rows.length; i++)
          Builder(
            builder: (context) {
              final row = rows[i];
              final f = row.friend;
              final title = PassportAchievement.values.where((a) => a.id == f.title).firstOrNull?.title;
              final tile = Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: row.me ? const Color(0x269F8CFF) : const Color(0x10FFFFFF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    if (social.showRanking)
                      SizedBox(
                        width: 26,
                        child: Text(
                          '${i + 1}',
                          style: ColituText.label.copyWith(color: i == 0 ? ColituColors.lilac : ColituColors.muted),
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.nick.trim().isEmpty ? loc.format('passport.id.collector', {'n': f.collector}) : f.nick,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ColituText.label,
                          ),
                          if (title != null)
                            Text(title, maxLines: 1, style: ColituText.small.copyWith(color: ColituColors.lilac)),
                        ],
                      ),
                    ),
                    Text('${row.count}/10', style: ColituText.label),
                    if (!row.me) ...[
                      const SizedBox(width: 8),
                      Semantics(
                        button: true,
                        label: loc['passport.friends.remove'],
                        child: ColituPressable(
                          onTap: () => social.removeFriend(f.collector),
                          child: const SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(CupertinoIcons.xmark, size: 14, color: ColituColors.dim),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
              return row.me ? tile : ColituPressable(onTap: () => onOpen(f), child: tile);
            },
          ),
        const SizedBox(height: 6),
        Text(
          loc['passport.friends.local'],
          textAlign: TextAlign.center,
          style: ColituText.small.copyWith(color: ColituColors.dim, fontSize: 11.5),
        ),
      ],
    );
  }
}

/// One row of the friends list; [me] is this passport.
typedef FriendRow = ({PassportFriend friend, bool me, int count});

/// Friends plus me, ranked by Origin stamps then by the sum of levels when
/// [ranking] is on; friends only (newest first) when it is off.
List<FriendRow> rankFriends(ColituPassport p, List<PassportFriend> friends, {required bool ranking, required String myName}) {
  final rows = <FriendRow>[for (final f in friends) (friend: f, me: false, count: f.count(ColituPassport.stamps))];
  if (!ranking) return rows;
  var myScore = 0;
  for (final s in ColituPassport.allStamps) {
    myScore += p.social.myLevel(s.code);
  }
  final me = PassportFriend(nick: myName, collector: p.goals.collectorNo, title: p.goals.title, levels: '', addedAt: 0);
  final all = [...rows, (friend: me, me: true, count: p.count)];
  int score(FriendRow r) => r.me ? myScore : r.friend.score;
  // Stable, like Android's sortedWith: equal rows keep their order.
  mergeSort(all, compare: (a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : score(b).compareTo(score(a));
  });
  return all;
}
