import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_duel.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_sections.dart';

/// Passport page, kept calm (Android PassportHome.kt): the cover and the
/// count, one "next up" goal, three small tiles (expeditions, collections,
/// achievements) that open their own sheets, then the stamps of the chosen
/// chapter. Rules and settings live behind the info button.
class PassportPage extends StatefulWidget {
  const PassportPage({super.key, required this.controller, required this.onConnect, this.showIntro = true});

  final ColituConnectionController controller;

  /// Connects (the shell's toggle, which also handles a missing plan).
  final Future<void> Function() onConnect;

  /// Tests switch the first-visit intro off.
  final bool showIntro;

  static Future<void> open(BuildContext context, ColituConnectionController controller, Future<void> Function() onConnect) {
    return Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => PassportPage(controller: controller, onConnect: onConnect)),
    );
  }

  @override
  State<PassportPage> createState() => _PassportPageState();
}

class _PassportPageState extends State<PassportPage> {
  var _chapter = 1;

  ColituConnectionController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.showIntro && !ColituPassport.I.social.introSeen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(showPassportIntro(context, c.planActive).then((_) => ColituPassport.I.social.introSeen = true));
      });
    }
  }

  void _connect(VPNServer? server) {
    if (server != null) unawaited(c.selectServer(server));
    if (!c.connected && !c.busy) unawaited(widget.onConnect());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ColituPassport.I, c, ColituLoc.I]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: passportInk,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Opacity(opacity: 0.9, child: Image(image: AssetImage(passportBgAsset), fit: BoxFit.cover)),
          ListView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, padding.top + 8, 20, padding.bottom + 28),
            children: [
              Row(
                children: [
                  ColituIconButton(
                    icon: CupertinoIcons.chevron_left,
                    size: 40,
                    tooltip: loc['passport.close'],
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(child: Text(loc['passport.title'], textAlign: TextAlign.center, style: ColituText.label)),
                  ColituIconButton(
                    icon: CupertinoIcons.qrcode_viewfinder,
                    size: 40,
                    tooltip: loc['passport.duel.title'],
                    onPressed: () => showPassportDuel(context),
                  ),
                  const SizedBox(width: 8),
                  ColituIconButton(
                    icon: CupertinoIcons.info,
                    size: 40,
                    tooltip: loc['passport.how'],
                    onPressed: () => showPassportPanel(context, loc['passport.how'], (_) => const _HowItWorks()),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _Hero(
                premium: c.planActive,
                onEdit: () => PassportIdentityPage.open(context, c.planActive),
                onLongPress: p.tester ? p.debugCycle : null,
              ),
              const SizedBox(height: 24),
              if (p.count == 0)
                _FirstSteps(onConnect: !c.connected && !c.busy ? () => _connect(null) : null)
              else
                _NextUpCard(
                  onOpen: () => showPassportPanel(
                    context,
                    loc['passport.nx.title'],
                    (sheet) => _NextGoalDetail(
                      controller: c,
                      onGo: (server) {
                        Navigator.of(sheet).pop();
                        _connect(server);
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _StatTile(
                      icon: CupertinoIcons.paperplane_fill,
                      value: '${p.weekly.goals().where(p.weekly.done).length}/3',
                      label: loc['passport.tile.week'],
                      onTap: () => showPassportPanel(context, loc['passport.week.title'], (_) => const WeeklyCard()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _StatTile(
                      icon: CupertinoIcons.square_grid_2x2_fill,
                      value:
                          '${PassportCollection.values.where(p.goals.completed).length}/${PassportCollection.values.length}',
                      label: loc['passport.tile.sets'],
                      onTap: () => showPassportPanel(context, loc['passport.tab.sets'], (_) => const CollectionsList()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _StatTile(
                      icon: CupertinoIcons.checkmark_seal_fill,
                      value:
                          '${PassportAchievement.values.where(p.goals.achieved).length}/${PassportAchievement.values.length}',
                      label: loc['passport.tile.badges'],
                      onTap: () => showPassportPanel(context, loc['passport.tab.badges'], (_) => const AchievementsList()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              _ChapterTabs(chapter: _chapter, onChange: (n) => setState(() => _chapter = n)),
              const SizedBox(height: 18),
              if (_chapter == 3)
                const LegacyChapter()
              else ...[
                if (_chapter == 2 && !p.chapter2Open) ...[
                  Text(loc['passport.ch2.locked'], textAlign: TextAlign.center, style: ColituText.small),
                  const SizedBox(height: 16),
                ],
                _StampGrid(
                  stamps: _chapter == 2 ? ColituPassport.chapter2 : ColituPassport.stamps,
                  onOpen: (stamp) => showStampSheet(context, c, stamp, onConnectTo: _connect),
                ),
              ],
              const _SpecialStamps(),
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(CupertinoIcons.lock_fill, size: 12, color: ColituColors.dim),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      loc['passport.local'],
                      textAlign: TextAlign.center,
                      style: ColituText.small.copyWith(color: ColituColors.dim, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Big cover, the count and the holder line; a tap edits the passport.
class _Hero extends StatelessWidget {
  const _Hero({required this.premium, required this.onEdit, this.onLongPress});

  final bool premium;
  final VoidCallback onEdit;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final count = p.count;
    final total = ColituPassport.stamps.length;
    final coverHeight = MediaQuery.sizeOf(context).height < 700 ? 170.0 : 210.0;
    return Column(
      children: [
        Semantics(
          button: true,
          label: loc['passport.id.edit'],
          child: GestureDetector(
            onTap: onEdit,
            onLongPress: onLongPress,
            child: SizedBox(
              width: coverHeight * 1.25,
              height: coverHeight * 1.25,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [Color(0x559F8CFF), Color(0x009F8CFF)]),
                      ),
                    ),
                  ),
                  PassportCover(theme: p.goals.activeCover(premium), height: coverHeight),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$count', style: const TextStyle(color: ColituColors.lilac)),
              TextSpan(text: ' / $total', style: const TextStyle(color: ColituColors.muted)),
            ],
          ),
          style: ColituText.display.copyWith(fontSize: 40, fontWeight: FontWeight.w700),
        ),
        Text(loc['passport.countries'], style: ColituText.small),
        const SizedBox(height: 10),
        SizedBox(
          width: 160,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: count / total),
            duration: const Duration(milliseconds: 700),
            builder: (context, value, _) => PassportBar(fraction: value),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          identityLine(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ColituText.small.copyWith(color: ColituColors.lilac, fontSize: 12),
        ),
      ],
    );
  }
}

/// Soft glass card used on this page (lighter than the app's panels).
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ColituRadius.lg),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x229F8CFF), Color(0x0F9F8CFF)],
        ),
        border: Border.all(color: const Color(0x339F8CFF)),
      ),
      child: child,
    );
    return onTap == null ? card : ColituPressable(onTap: onTap, child: card);
  }
}

class _NextUpCard extends StatelessWidget {
  const _NextUpCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final goal = nextGoal();
    return Semantics(
      button: true,
      child: _GlassCard(
        onTap: onOpen,
        child: Row(
          children: [
            GoalRing(
              fraction: goal.fraction,
              size: 52,
              stroke: 4,
              child: Icon(goal.icon, size: 18, color: ColituColors.lilac),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ColituLoc.I['passport.next'], style: ColituText.kicker.copyWith(color: ColituColors.lilac)),
                  const SizedBox(height: 3),
                  Text(goal.text, style: ColituText.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Icon(CupertinoIcons.chevron_right, size: 16, color: ColituColors.muted),
          ],
        ),
      ),
    );
  }
}

/// The next goal explained: what it is, how to reach it, today's numbers and a way to act.
class _NextGoalDetail extends StatelessWidget {
  const _NextGoalDetail({required this.controller, required this.onGo});

  final ColituConnectionController controller;
  final void Function(VPNServer? server) onGo;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = controller;
    final p = ColituPassport.I;
    final goal = nextGoal();
    final (minutes, pieces) = p.today;
    final stamp = goal.kind == GoalKind.level && goal.code != null ? ColituPassport.stampOf(goal.code!) : null;
    final country = goal.code == null ? null : loc.countryName(goal.code!);
    final body = switch (goal.kind) {
      GoalKind.today => loc['passport.nx.today'],
      GoalKind.level => loc.format('passport.nx.level', {'country': country, 'level': goal.target, 'n': goal.left}),
      GoalKind.done => loc['passport.nx.done'],
    };
    final server = goal.code == null
        ? null
        : c.rankedServers
              .where((s) => !s.isMultihop && s.isAvailable && ColituPassport.stampFor(s.countryCode)?.code == goal.code)
              .firstOrNull;
    final connected = c.connectedServer;
    final onThatCountry =
        c.connected && connected != null && ColituPassport.stampFor(connected.countryCode)?.code == goal.code;
    Widget? action;
    if (goal.kind == GoalKind.level && server != null && !onThatCountry) {
      action = ColituButton(label: loc.format('passport.connectTo', {'country': country}), onPressed: () => onGo(server));
    } else if (!c.connected && goal.kind != GoalKind.done) {
      action = ColituButton(label: loc['home.connect'], onPressed: c.busy ? null : () => onGo(null));
    } else if (c.connected) {
      action = Text(
        loc['passport.nx.counting'],
        textAlign: TextAlign.center,
        style: ColituText.small.copyWith(color: ColituColors.lilac),
      );
    }
    return Column(
      children: [
        GoalRing(
          fraction: goal.fraction,
          size: 110,
          stroke: 7,
          child: stamp != null
              ? StampArt(stamp: stamp, progress: p.progressOf(stamp.code), lockSize: 0, size: 70)
              : Icon(goal.icon, size: 30, color: ColituColors.lilac),
        ),
        const SizedBox(height: 16),
        Text(goal.text, textAlign: TextAlign.center, style: ColituText.h2),
        const SizedBox(height: 10),
        Text(body, textAlign: TextAlign.center, style: ColituText.muted),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(child: _GoalStat(label: loc['passport.nx.minutes'], value: '$minutes')),
            const SizedBox(width: 10),
            Expanded(
              child: _GoalStat(label: loc['passport.nx.pieces'], value: '$pieces/${ColituPassport.pieceMinutes.length}'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ?action,
      ],
    );
  }
}

class _GoalStat extends StatelessWidget {
  const _GoalStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(ColituRadius.md),
        border: Border.all(color: ColituColors.line),
      ),
      child: Column(
        children: [
          Text(value, style: ColituText.h2),
          Text(label, style: ColituText.small.copyWith(fontSize: 11.5), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

const _steps = [
  (CupertinoIcons.power, 'passport.step1', 'passport.step1b'),
  (CupertinoIcons.star_fill, 'passport.step2', 'passport.step2b'),
  (CupertinoIcons.arrow_up, 'passport.step3', 'passport.step3b'),
];

/// First visit: the whole game in three steps, and a way to start.
class _FirstSteps extends StatelessWidget {
  const _FirstSteps({this.onConnect});

  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return _GlassCard(
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (icon, top, bottom) in _steps)
                Expanded(
                  child: Column(
                    children: [
                      _RoundIcon(icon: icon, size: 40),
                      const SizedBox(height: 8),
                      Text(
                        loc[top],
                        textAlign: TextAlign.center,
                        style: ColituText.small.copyWith(color: ColituColors.text, fontSize: 12),
                      ),
                      Text(
                        loc[bottom],
                        textAlign: TextAlign.center,
                        style: ColituText.small.copyWith(color: ColituColors.lilac, fontSize: 12),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (onConnect != null) ...[
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 200),
              child: ColituButton(label: loc['home.connect'], onPressed: onConnect, expand: false, height: 46),
            ),
          ],
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: Color(0x269F8CFF), shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.45, color: ColituColors.lilac),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.value, required this.label, required this.onTap});

  final IconData icon;
  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: ColituPressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(ColituRadius.md),
            border: Border.all(color: ColituColors.line),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: ColituColors.lilac),
              const SizedBox(height: 6),
              Text(value, style: ColituText.label),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ColituText.small.copyWith(fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chapter names as quiet text tabs with an underline; closed ones are dimmed.
class _ChapterTabs extends StatelessWidget {
  const _ChapterTabs({required this.chapter, required this.onChange});

  final int chapter;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final n in const [1, 2, 3])
          Builder(
            builder: (context) {
              final open = switch (n) {
                1 => true,
                2 => p.chapter2Open,
                _ => p.goals.chapter3Open,
              };
              final active = chapter == n;
              return Semantics(
                button: true,
                selected: active,
                child: ColituPressable(
                  onTap: () => onChange(n),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Column(
                      children: [
                        Text('0$n', style: ColituText.kicker.copyWith(color: active ? ColituColors.lilac : ColituColors.dim)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!open) ...[
                              const Icon(CupertinoIcons.lock_fill, size: 12, color: ColituColors.dim),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              loc['passport.chName$n'],
                              style: ColituText.label.copyWith(color: active ? ColituColors.text : ColituColors.muted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 28,
                          height: 2,
                          decoration: BoxDecoration(
                            color: active ? ColituColors.lilac : Colors.transparent,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Three stamps per row; only the name and a dot in the level's colour.
class _StampGrid extends StatelessWidget {
  const _StampGrid({required this.stamps, required this.onOpen});

  final List<ColituStamp> stamps;
  final ValueChanged<ColituStamp> onOpen;

  @override
  Widget build(BuildContext context) {
    final p = ColituPassport.I;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final cell = (constraints.maxWidth - gap * 2) / 3;
        final rows = <Widget>[];
        for (var i = 0; i < stamps.length; i += 3) {
          final row = stamps.sublist(i, math.min(i + 3, stamps.length));
          if (rows.isNotEmpty) rows.add(const SizedBox(height: 18));
          rows.add(
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var j = 0; j < row.length; j++) ...[
                  if (j > 0) const SizedBox(width: gap),
                  SizedBox(
                    width: cell,
                    child: Semantics(
                      button: true,
                      label: ColituLoc.I.countryName(row[j].code),
                      child: ColituPressable(
                        onTap: () => onOpen(row[j]),
                        child: _GridStamp(stamp: row[j], progress: p.progressOf(row[j].code)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }
}

class _GridStamp extends StatelessWidget {
  const _GridStamp({required this.stamp, required this.progress});

  final ColituStamp stamp;
  final StampProgress progress;

  @override
  Widget build(BuildContext context) {
    final level = progress.level;
    return Column(
      children: [
        StampArt(stamp: stamp, progress: progress, lockSize: 30),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (level != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: levelColor(level), shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                ColituLoc.I.countryName(stamp.code),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ColituText.small.copyWith(
                  fontSize: 12,
                  color: progress.unlocked ? ColituColors.text : ColituColors.dim,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Rules in four steps, today's count and the passport settings.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final (minutes, pieces) = p.today;
        final social = p.social;
        Widget toggle(String title, bool value, ValueChanged<bool> onChanged, {String? hint}) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: ColituText.label),
                    if (hint != null) Text(hint, style: ColituText.small.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              CupertinoSwitch(value: value, activeTrackColor: ColituColors.violet, onChanged: onChanged),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (icon, title, body) in const [
              (CupertinoIcons.power, 'passport.how1', 'passport.how1b'),
              (CupertinoIcons.star_fill, 'passport.how2', 'passport.how2b'),
              (CupertinoIcons.arrow_up, 'passport.how3', 'passport.how3b'),
              (CupertinoIcons.square_grid_2x2_fill, 'passport.how4', 'passport.how4b'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RoundIcon(icon: icon, size: 36),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(loc[title], style: ColituText.label),
                          Text(loc[body], style: ColituText.small),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              loc.format('passport.today', {'m': minutes, 'p': pieces}),
              style: ColituText.small.copyWith(color: ColituColors.lilac),
            ),
            const SizedBox(height: 10),
            toggle(loc['passport.notify'], p.notify, (v) => p.notify = v),
            toggle(loc['passport.set.sound'], social.sound, social.updateSound),
            toggle(loc['passport.set.haptics'], social.haptics, social.updateHaptics),
            toggle(loc['passport.set.metrics'], social.metrics, social.updateMetrics, hint: loc['passport.set.metricsBody']),
            const SizedBox(height: 14),
            Text(loc['passport.local'], style: ColituText.small.copyWith(color: ColituColors.dim)),
          ],
        );
      },
    );
  }
}

/// Special stamps outside the chapters (the Companion stamp).
class _SpecialStamps extends StatelessWidget {
  const _SpecialStamps();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final social = p.social;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        children: [
          Text(loc['passport.special'], textAlign: TextAlign.center, style: ColituText.kicker.copyWith(color: ColituColors.dim)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                // Tester accounts: a long press grants the Companion stamp (with its reveal).
                onLongPress: p.tester ? social.markCompanion : null,
                child: CompanionStamp(earned: social.companion, size: 96),
              ),
              const SizedBox(width: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Companion',
                      style: ColituText.label.copyWith(color: social.companion ? ColituColors.text : ColituColors.muted),
                    ),
                    Text(
                      social.companion ? loc['passport.companion.have'] : loc['passport.companion.how'],
                      style: ColituText.small.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A tall bottom sheet with a title, scrolling content and a close link.
Future<void> showPassportPanel(BuildContext context, String title, Widget Function(BuildContext sheet) content) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x99000000),
    builder: (sheet) => PassportSheetFrame(
      title: title,
      maxHeight: MediaQuery.sizeOf(sheet).height * 0.86,
      child: content(sheet),
    ),
  );
}

/// The frame of the passport's bottom sheets.
class PassportSheetFrame extends StatelessWidget {
  const PassportSheetFrame({super.key, this.title, required this.child, this.maxHeight, this.background});

  final String? title;
  final Widget child;
  final double? maxHeight;
  final String? background;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(top: Radius.circular(ColituRadius.lg));
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight ?? double.infinity),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF13112E),
          borderRadius: radius,
          border: Border.all(color: ColituColors.lineStrong),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            children: [
              if (background != null) Positioned.fill(child: Image.asset(background!, fit: BoxFit.cover)),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 10, 20, 12 + MediaQuery.paddingOf(context).bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(color: ColituColors.lineStrong, borderRadius: BorderRadius.circular(99)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (title != null) ...[
                      Text(title!, style: ColituText.h2),
                      const SizedBox(height: 14),
                    ],
                    Flexible(child: SingleChildScrollView(child: child)),
                    const SizedBox(height: 8),
                    Center(
                      child: ColituLinkButton(
                        label: ColituLoc.I['passport.close'],
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// First visit: the cover turns in, the passport is named, the three steps
/// arrive one by one, then "Start". Shown once; plain with Reduce Motion.
Future<void> showPassportIntro(BuildContext context, bool premium) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (dialog, _, _) => _PassportIntro(premium: premium),
    transitionBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}

class _PassportIntro extends StatefulWidget {
  const _PassportIntro({required this.premium});

  final bool premium;

  @override
  State<_PassportIntro> createState() => _PassportIntroState();
}

class _PassportIntroState extends State<_PassportIntro> with SingleTickerProviderStateMixin {
  late final _time = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_time.isAnimating || _time.isCompleted) return;
    if (motionAllowed(context)) {
      _time.forward();
    } else {
      _time.value = 1;
    }
  }

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return Material(
      color: passportInk,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Opacity(opacity: 0.9, child: Image(image: AssetImage(passportBgAsset), fit: BoxFit.cover)),
          SafeArea(
            child: AnimatedBuilder(
              animation: _time,
              builder: (context, _) {
                final t = _time.value;
                double span(double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);
                final cover = Curves.fastOutSlowIn.transform(span(0, 0.35));
                final title = span(0.3, 0.5);
                final button = span(0.9, 1);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 260,
                        height: 220,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: cover,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(colors: [Color(0x669F8CFF), Color(0x009F8CFF)]),
                                ),
                                child: SizedBox(width: 260, height: 260),
                              ),
                            ),
                            Opacity(
                              opacity: cover,
                              child: Transform(
                                alignment: Alignment.center,
                                transform: Matrix4.identity()
                                  ..setEntry(3, 2, 0.0012)
                                  ..rotateY((1 - cover) * -70 * math.pi / 180)
                                  ..scaleByDouble(0.8 + 0.2 * cover, 0.8 + 0.2 * cover, 1, 1),
                                child: PassportCover(
                                  theme: ColituPassport.I.goals.activeCover(widget.premium),
                                  height: 200,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      Opacity(
                        opacity: title,
                        child: Transform.translate(
                          offset: Offset(0, (1 - title) * 20),
                          child: Column(
                            children: [
                              Text('COLITU PASSPORT', style: ColituText.kicker.copyWith(color: ColituColors.lilac)),
                              const SizedBox(height: 8),
                              Text(loc['passport.intro.title'], textAlign: TextAlign.center, style: ColituText.h1),
                              const SizedBox(height: 6),
                              Text(loc['passport.intro.body'], textAlign: TextAlign.center, style: ColituText.muted),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      for (var i = 0; i < _steps.length; i++)
                        Builder(
                          builder: (context) {
                            final step = span(0.5 + i * 0.12, 0.66 + i * 0.12);
                            final (icon, top, bottom) = _steps[i];
                            return Opacity(
                              opacity: step,
                              child: Transform.translate(
                                offset: Offset((1 - step) * 40, 0),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 5),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0x149F8CFF),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    children: [
                                      _RoundIcon(icon: icon, size: 36),
                                      const SizedBox(width: 12),
                                      Expanded(child: Text(loc[top], style: ColituText.label)),
                                      Text(loc[bottom], style: ColituText.small.copyWith(color: ColituColors.lilac)),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 26),
                      Opacity(
                        opacity: button,
                        child: ColituButton(
                          label: loc['passport.intro.start'],
                          onPressed: button > 0.5 ? () => Navigator.of(context).pop() : null,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
