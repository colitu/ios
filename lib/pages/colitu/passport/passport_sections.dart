import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_page.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_share.dart';

// Collections, achievements, weekly expeditions, Chapter 03, the stamp sheet
// and the passport editor (Android PassportSections.kt, PassportP3.kt,
// PassportScreen.kt StampSheet).

// ── Collections ────────────────────────────────────────────────────────────

class CollectionsList extends StatelessWidget {
  const CollectionsList({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    return Column(
      children: [
        for (final c in PassportCollection.values)
          Builder(
            builder: (context) {
              final (have, need) = p.goals.progress(c);
              final earned = p.goals.completed(c);
              final hidden = c.secret && !earned;
              final String reward;
              if (earned) {
                reward = loc.format('passport.set.done', {
                  'date': loc.date(DateTime.fromMillisecondsSinceEpoch(p.goals.earnedAt('c_${c.id}'))),
                });
              } else if (c.cover != null) {
                reward = loc.format('passport.set.rewardCover', {'cover': coverName(c.cover!)});
              } else {
                reward = loc['passport.set.rewardSeal'];
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ColituPanel(
                  padding: const EdgeInsets.all(14),
                  radius: ColituRadius.md,
                  glow: earned,
                  child: Row(
                    children: [
                      PassportSeal(collection: c, earned: earned, size: 72),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    hidden ? '???' : c.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ColituText.label,
                                  ),
                                ),
                                Text(
                                  '$have/$need',
                                  style: ColituText.label.copyWith(color: earned ? sealColor(c) : ColituColors.muted),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            if (hidden)
                              Text(loc['passport.set.secret'], style: ColituText.small)
                            else if (c == PassportCollection.goldRush)
                              Text(loc['passport.set.goldRush'], style: ColituText.small)
                            else
                              Wrap(
                                spacing: 6,
                                children: [
                                  for (final code in c.codes)
                                    Opacity(
                                      opacity: p.unlockedAnywhere(code) ? 1 : 0.3,
                                      child: ColituFlag(code, size: 22),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 6),
                            Text(
                              reward,
                              style: ColituText.small.copyWith(
                                fontSize: 11.5,
                                color: earned ? sealColor(c) : ColituColors.dim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        Text(loc['passport.set.nextChapter'], textAlign: TextAlign.center, style: ColituText.small),
      ],
    );
  }
}

// ── Achievements ───────────────────────────────────────────────────────────

class AchievementsList extends StatelessWidget {
  const AchievementsList({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => Column(
        children: [
          for (final a in PassportAchievement.values)
            Builder(
              builder: (context) {
                final earned = p.goals.achieved(a);
                final hidden = a.secret && !earned;
                final inUse = p.goals.title == a.id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ColituPanel(
                    padding: const EdgeInsets.all(14),
                    radius: ColituRadius.md,
                    glow: inUse,
                    child: Row(
                      children: [
                        AchievementBadge(achievement: a, earned: earned, size: 48),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                hidden ? '???' : a.title,
                                maxLines: 1,
                                style: ColituText.label.copyWith(color: earned ? ColituColors.text : ColituColors.muted),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hidden ? loc['passport.ach.secret'] : loc['passport.ach.${a.id}'],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: ColituText.small,
                              ),
                              if (earned) ...[
                                const SizedBox(height: 8),
                                ColituChip(
                                  label: inUse ? loc['passport.ach.inUse'] : loc['passport.ach.use'],
                                  selected: inUse,
                                  onTap: () => p.goals.updateTitle(inUse ? null : a.id),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ── Weekly expeditions ─────────────────────────────────────────────────────

/// This week's three goals; no countdown, a missed week costs nothing.
class WeeklyCard extends StatelessWidget {
  const WeeklyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final weekly = ColituPassport.I.weekly;
    return ColituPanel(
      padding: const EdgeInsets.all(16),
      radius: ColituRadius.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(loc['passport.week.title'], style: ColituText.label)),
              Text(
                loc.format('passport.week.total', {'n': weekly.total}),
                style: ColituText.small.copyWith(color: ColituColors.lilac),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final goal in weekly.goals())
            Builder(
              builder: (context) {
                final have = weekly.progress(goal).clamp(0, goal.target);
                final done = have >= goal.target;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: done ? const Color(0x339F8CFF) : ColituColors.surface2,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          done ? CupertinoIcons.checkmark : expeditionIcon(goal),
                          size: 16,
                          color: done ? ColituColors.lilac : ColituColors.muted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc['passport.x.${goal.id}'],
                              style: ColituText.small.copyWith(color: done ? ColituColors.text : ColituColors.muted),
                            ),
                            const SizedBox(height: 5),
                            PassportBar(fraction: have / goal.target, height: 5),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$have/${goal.target}',
                        style: ColituText.small.copyWith(color: done ? ColituColors.lilac : ColituColors.dim),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 6),
          Text(loc['passport.week.note'], style: ColituText.small.copyWith(color: ColituColors.dim, fontSize: 11.5)),
        ],
      ),
    );
  }
}

// ── Chapter 03 ─────────────────────────────────────────────────────────────

/// Chapter 03 — Legacy: mastery goals with their progress, open or not.
class LegacyChapter extends StatelessWidget {
  const LegacyChapter({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final goals = ColituPassport.I.goals;
    final rows = [
      (loc['passport.legacy.gold1'], goals.legacy(StampLevel.gold, ColituPassport.stamps), StampLevel.gold),
      (loc['passport.legacy.diamond1'], goals.legacy(StampLevel.diamond, ColituPassport.stamps), StampLevel.diamond),
      (loc['passport.legacy.gold2'], goals.legacy(StampLevel.gold, ColituPassport.chapter2), StampLevel.gold),
    ];
    return Column(
      children: [
        if (!goals.chapter3Open) ...[
          Text(loc['passport.legacy.locked'], textAlign: TextAlign.center, style: ColituText.small),
          const SizedBox(height: 10),
        ],
        for (final (label, have, level) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ColituPanel(
              padding: const EdgeInsets.all(16),
              radius: ColituRadius.md,
              glow: have >= 10,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(label, style: ColituText.label)),
                      Text('$have/10', style: ColituText.label.copyWith(color: levelColor(level))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  PassportBar(fraction: have / 10, height: 8, color: levelColor(level)),
                ],
              ),
            ),
          ),
        Text(
          loc['passport.legacy.keep'],
          textAlign: TextAlign.center,
          style: ColituText.small.copyWith(color: ColituColors.dim),
        ),
      ],
    );
  }
}

// ── Stamp sheet ────────────────────────────────────────────────────────────

class LevelChip extends StatelessWidget {
  const LevelChip({super.key, required this.level});

  final StampLevel level;

  @override
  Widget build(BuildContext context) {
    final color = levelColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        levelName(level).toUpperCase(),
        style: ColituText.kicker.copyWith(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// Bottom sheet for one stamp: its live puzzle, level and count; share it or
/// connect to its country.
Future<void> showStampSheet(
  BuildContext context,
  ColituConnectionController controller,
  ColituStamp stamp, {
  required void Function(VPNServer server) onConnectTo,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x99000000),
    builder: (sheet) => PassportSheetFrame(
      background: passportSheetBgAsset,
      maxHeight: MediaQuery.sizeOf(sheet).height * 0.92,
      child: StampSheetBody(
        controller: controller,
        stamp: stamp,
        onConnectTo: (server) {
          Navigator.of(sheet).pop();
          onConnectTo(server);
        },
      ),
    ),
  );
}

class StampSheetBody extends StatelessWidget {
  const StampSheetBody({super.key, required this.controller, required this.stamp, required this.onConnectTo});

  final ColituConnectionController controller;
  final ColituStamp stamp;
  final void Function(VPNServer server) onConnectTo;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final country = loc.countryName(stamp.code);
        final progress = p.progressOf(stamp.code);
        final level = progress.level;
        final inCountry = controller.rankedServers
            .where((s) => !s.isMultihop && ColituPassport.stampFor(s.countryCode)?.code == stamp.code)
            .toList();
        final server = inCountry.where((s) => s.isAvailable).firstOrNull;
        final children = <Widget>[
          Center(
            child: StampArt(stamp: stamp, progress: progress, lockSize: 48, puzzle: true, live: true, size: 240),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            children: [
              Text(country, style: ColituText.h1.copyWith(fontSize: 28)),
              if (level != null) LevelChip(level: level),
            ],
          ),
          const SizedBox(height: 4),
        ];
        if (level != null) {
          final meta = [
            ?progress.city,
            if (progress.minutes > 0) usedTime(progress.minutes),
          ].join(' · ');
          final goal = progress.mastered
              ? loc['passport.masteredShort']
              : level == StampLevel.diamond
              ? loc.format('passport.toMaster', {'n': progress.toNext})
              : loc.format('passport.toNext', {
                  'level': levelName(StampLevel.values[level.index + 1]),
                  'n': progress.toNext,
                });
          children.addAll([
            Text(
              meta.isEmpty ? loc.format('passport.stampNo', {'n': stampNumber(stamp)}) : meta,
              textAlign: TextAlign.center,
              style: ColituText.small,
            ),
            const SizedBox(height: 16),
            if (!progress.mastered) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SegmentBar(filled: progress.levelPieces, color: levelColor(level)),
              ),
              const SizedBox(height: 10),
            ],
            Text(goal, textAlign: TextAlign.center, style: ColituText.label.copyWith(color: levelColor(level))),
          ]);
        } else {
          final hint = server != null
              ? loc['passport.lockedHint']
              : inCountry.isEmpty
              ? loc.format('passport.planDesc', {'country': country})
              : loc.format('passport.offlineDesc', {'country': country});
          children.add(Text(hint, textAlign: TextAlign.center, style: ColituText.muted));
        }
        children.add(const SizedBox(height: 22));
        if (level != null) {
          children.add(
            Builder(
              builder: (button) => ColituButton(
                label: loc['passport.shareStamp'],
                onPressed: () => unawaited(sharePassport(button, stamp: stamp, premium: controller.planActive)),
              ),
            ),
          );
        } else if (server != null) {
          children.add(
            ColituButton(
              label: loc.format('passport.connectTo', {'country': country}),
              onPressed: () => onConnectTo(server),
            ),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      },
    );
  }
}

// ── Passport editor ────────────────────────────────────────────────────────

/// Passport editor, full screen: a live preview (cover and the holder page)
/// on top, then the nickname, cover, title and favourite stamp. Locked
/// choices stay visible with what opens them. The save button hides while
/// the keyboard is up (the keyboard's Done saves).
class PassportIdentityPage extends StatefulWidget {
  const PassportIdentityPage({super.key, required this.premium});

  final bool premium;

  static Future<void> open(BuildContext context, bool premium) => Navigator.of(context).push(
    CupertinoPageRoute<void>(fullscreenDialog: true, builder: (_) => PassportIdentityPage(premium: premium)),
  );

  @override
  State<PassportIdentityPage> createState() => _PassportIdentityPageState();
}

class _PassportIdentityPageState extends State<PassportIdentityPage> {
  late final _nick = TextEditingController(text: ColituPassport.I.goals.nickname);

  @override
  void dispose() {
    _nick.dispose();
    super.dispose();
  }

  void _close() {
    final goals = ColituPassport.I.goals;
    if (_nick.text.trim() != goals.nickname) goals.updateNickname(_nick.text);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ColituPassport.I, _nick, ColituLoc.I]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final goals = p.goals;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final active = goals.activeCover(widget.premium);
    final open = goals.covers(widget.premium);
    final unlocked = ColituPassport.allStamps.where((s) => p.progressOf(s.code).unlocked).toList();
    return Scaffold(
      backgroundColor: passportInk,
      resizeToAvoidBottomInset: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Opacity(opacity: 0.85, child: Image(image: AssetImage(passportBgAsset), fit: BoxFit.cover)),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      ColituIconButton(
                        icon: CupertinoIcons.xmark,
                        size: 40,
                        tooltip: loc['passport.close'],
                        onPressed: _close,
                      ),
                      Expanded(child: Text(loc['passport.id.edit'], textAlign: TextAlign.center, style: ColituText.label)),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      const SizedBox(height: 6),
                      Center(child: PassportCover(theme: active, height: 170)),
                      const SizedBox(height: 18),
                      _HolderPage(nick: _nick.text),
                      const SizedBox(height: 22),
                      // The field carries its own label.
                      Padding(
                        padding: const EdgeInsets.only(bottom: 22),
                        child: ColituField(
                          controller: _nick,
                          label: loc['passport.id.nick'],
                          hint: loc['passport.id.nickHint'],
                          maxLength: 20,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => goals.updateNickname(_nick.text),
                        ),
                      ),
                      _EditorSection(
                        title: loc['passport.id.cover'],
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final theme in CoverTheme.values) ...[
                                if (theme != CoverTheme.values.first) const SizedBox(width: 12),
                                _CoverChoice(
                                  theme: theme,
                                  selected: theme == active,
                                  unlocked: open.contains(theme),
                                  onPick: () => goals.updateCover(theme),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      _EditorSection(
                        title: loc['passport.id.title'],
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ColituChip(
                              label: loc['passport.id.noTitle'],
                              selected: goals.title == null,
                              onTap: () => goals.updateTitle(null),
                            ),
                            for (final a in PassportAchievement.values)
                              if (goals.achieved(a))
                                ColituChip(label: a.title, selected: goals.title == a.id, onTap: () => goals.updateTitle(a.id))
                              else
                                _LockedChip(label: a.secret ? '???' : a.title),
                          ],
                        ),
                      ),
                      _EditorSection(
                        title: loc['passport.id.favorite'],
                        child: unlocked.isEmpty
                            ? Text(loc['passport.id.noStamps'], style: ColituText.small)
                            : SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final s in unlocked) ...[
                                      if (s != unlocked.first) const SizedBox(width: 10),
                                      _FavoriteChoice(
                                        stamp: s,
                                        selected: goals.favorite == s.code,
                                        onTap: () => goals.updateFavorite(goals.favorite == s.code ? null : s.code),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
                // Hidden while the keyboard is up: it would cover the name field.
                if (!keyboard)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                    child: ColituButton(key: const ValueKey('passportSave'), label: loc['passport.id.save'], onPressed: _close),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The holder page: name, title, collector number and favourite stamp.
class _HolderPage extends StatelessWidget {
  const _HolderPage({required this.nick});

  final String nick;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    final goals = p.goals;
    final fav = goals.favorite == null ? null : ColituPassport.stampOf(goals.favorite!);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ColituRadius.md),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x269F8CFF), Color(0x0F9F8CFF)],
        ),
        border: Border.all(color: const Color(0x339F8CFF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(loc['passport.id.holder'], style: ColituText.kicker.copyWith(color: ColituColors.dim)),
                Text(nick.trim().isEmpty ? '—' : nick.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: ColituText.h2),
                const SizedBox(height: 8),
                Text(loc['passport.id.title'].toUpperCase(), style: ColituText.kicker.copyWith(color: ColituColors.dim)),
                Text(
                  goals.titleOf(goals.title) ?? loc['passport.id.noTitle'],
                  maxLines: 1,
                  style: ColituText.label.copyWith(color: ColituColors.lilac),
                ),
                const SizedBox(height: 8),
                Text(
                  loc.format('passport.id.collector', {'n': goals.collectorNo}),
                  style: ColituText.small.copyWith(color: ColituColors.muted),
                ),
              ],
            ),
          ),
          if (fav != null) ...[
            const SizedBox(width: 12),
            StampArt(stamp: fav, progress: p.progressOf(fav.code), lockSize: 0, size: 84),
          ],
        ],
      ),
    );
  }
}

class _EditorSection extends StatelessWidget {
  const _EditorSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ColituText.label),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _CoverChoice extends StatelessWidget {
  const _CoverChoice({required this.theme, required this.selected, required this.unlocked, required this.onPick});

  final CoverTheme theme;
  final bool selected;
  final bool unlocked;
  final VoidCallback onPick;

  /// What opens a locked cover.
  String _requirement() {
    final loc = ColituLoc.I;
    if (theme == CoverTheme.premium) return loc['passport.req.premium'];
    final set = PassportCollection.values.where((c) => c.cover == theme).firstOrNull;
    return set == null ? '' : loc.format('passport.req.set', {'set': set.title});
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: unlocked,
      selected: selected,
      child: ColituPressable(
        onTap: unlocked ? onPick : null,
        child: SizedBox(
          width: 96,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: selected ? const Color(0x339F8CFF) : const Color(0x10FFFFFF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: selected ? ColituColors.lilac : ColituColors.line, width: selected ? 2 : 1),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(opacity: unlocked ? 1 : 0.35, child: PassportCover(theme: theme, height: 84)),
                    if (!unlocked) const Icon(CupertinoIcons.lock_fill, size: 18, color: ColituColors.text),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                coverName(theme),
                style: ColituText.small.copyWith(fontSize: 12, color: selected ? ColituColors.lilac : ColituColors.text),
              ),
              if (!unlocked)
                Text(
                  _requirement(),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: ColituText.small.copyWith(fontSize: 10.5, color: ColituColors.dim),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteChoice extends StatelessWidget {
  const _FavoriteChoice({required this.stamp, required this.selected, required this.onTap});

  final ColituStamp stamp;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: ColituLoc.I.countryName(stamp.code),
      child: ColituPressable(
        onTap: onTap,
        child: Container(
          width: 78,
          height: 78,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: selected ? const Color(0x339F8CFF) : const Color(0x10FFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? ColituColors.lilac : ColituColors.line, width: selected ? 2 : 1),
          ),
          child: StampArt(stamp: stamp, progress: ColituPassport.I.progressOf(stamp.code), lockSize: 0),
        ),
      ),
    );
  }
}

class _LockedChip extends StatelessWidget {
  const _LockedChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: ColituColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.lock_fill, size: 12, color: ColituColors.dim),
          const SizedBox(width: 6),
          Text(label, style: ColituText.small.copyWith(color: ColituColors.dim)),
        ],
      ),
    );
  }
}
