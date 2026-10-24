import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/passport/passport_effects.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_share.dart';

// Reward animations (Android PassportReveal.kt): the cinematic reveal for a
// new stamp or level, the flying piece, the seal, the turning achievement
// card, the chapter, the visa stamp and the Companion stamp. With Reduce
// Motion they open in their final state with a short fade.

/// Shows one reward and completes when it is closed.
Future<void> showPassportReward(BuildContext context, StampEvent event, {required bool premium}) {
  final Widget? body = switch (event.kind) {
    StampEventKind.piece => ColituPassport.stampOf(event.code) == null ? null : _PieceReveal(event: event),
    StampEventKind.collected => PassportCollection.values.any((c) => c.id == event.code) ? _CollectionReveal(event: event) : null,
    StampEventKind.achieved => PassportAchievement.values.any((a) => a.id == event.code) ? _AchievementReveal(event: event) : null,
    StampEventKind.chapter => _ChapterReveal(event: event),
    StampEventKind.expedition => ExpeditionGoal.values.any((g) => g.id == event.code) ? _ExpeditionReveal(event: event) : null,
    StampEventKind.special => _SpecialReveal(event: event),
    // A country of a later chapter is kept silently until that chapter opens.
    _ => ColituPassport.stampOf(event.code) == null ? null : _CinematicReveal(event: event, premium: premium),
  };
  if (body == null) return Future.value();
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => body,
    transitionBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}

double _span(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

double _ease(double v) => Curves.fastOutSlowIn.transform(v);

/// Timeline shared by every reveal: one linear 0..1 clock, a sound at the
/// start, one haptic at [hitAt], optional self-close.
abstract class _RevealState<T extends StatefulWidget> extends State<T> with SingleTickerProviderStateMixin {
  Duration get duration;

  String? get sound;

  double get hitAt;

  void onHit();

  /// Closes by itself after this long (null: waits for a button).
  Duration? get autoClose => null;

  late final AnimationController time = AnimationController(vsync: this, duration: duration);
  var _started = false;
  var _hit = false;
  var _closed = false;

  double get t => time.value;

  @override
  void initState() {
    super.initState();
    time.addListener(_check);
  }

  void _check() {
    if (!_hit && time.value >= hitAt) {
      _hit = true;
      onHit();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final s = sound;
    if (s != null) unawaited(PassportEffects.sound(s));
    if (motionAllowed(context)) {
      time.forward();
    } else {
      time.value = 1;
    }
    final wait = autoClose;
    if (wait != null) Future.delayed(wait, close);
  }

  void close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    time.dispose();
    super.dispose();
  }

  Widget dim(double alpha, Widget child, {VoidCallback? onTap}) {
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedBuilder(
          animation: time,
          builder: (context, _) => ColoredBox(
            color: const Color(0xFF05040F).withValues(alpha: alpha * _span(t, 0, 0.12)),
            child: SafeArea(child: Center(child: child)),
          ),
        ),
      ),
    );
  }

  Widget buttons(double from, List<Widget> children) {
    final shown = _span(t, from, 1);
    return Opacity(
      opacity: shown,
      child: IgnorePointer(
        ignoring: shown < 0.5,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Widget _perspective({required double rotateY, double scale = 1, required Widget child}) => Transform(
  alignment: Alignment.center,
  transform: Matrix4.identity()
    ..setEntry(3, 2, 0.0012)
    ..rotateY(rotateY)
    ..scaleByDouble(scale, scale, 1, 1),
  child: child,
);

/// New stamp, new level or a finished Diamond: the screen dims, the stamp
/// appears, its material sweeps in from the left with a glint, then
/// "GERMANY UNLOCKED" and the Story button.
class _CinematicReveal extends StatefulWidget {
  const _CinematicReveal({required this.event, required this.premium});

  final StampEvent event;
  final bool premium;

  @override
  State<_CinematicReveal> createState() => _CinematicRevealState();
}

class _CinematicRevealState extends _RevealState<_CinematicReveal> {
  bool get levelUp => widget.event.kind != StampEventKind.unlocked;

  @override
  Duration get duration => const Duration(milliseconds: 2400);

  @override
  String get sound => levelUp ? 'level' : 'reveal';

  @override
  double get hitAt => 0.62;

  @override
  void onHit() => PassportEffects.confirm();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final e = widget.event;
    final stamp = ColituPassport.stampOf(e.code)!;
    final after = ColituPassport.I.progressOf(stamp.code);
    final before = levelUp ? after.copyWith(pieces: math.max(0, after.pieces - 1)) : StampProgress.empty;
    final country = loc.countryName(stamp.code);
    final kicker = levelUp ? loc['passport.r.newLevel'] : loc['passport.r.newStamp'];
    final title = switch (e.kind) {
      StampEventKind.levelUp => loc.format('passport.r.levelUnlocked', {'level': levelName(e.level!)}),
      StampEventKind.mastered => loc['passport.masteredShort'],
      _ => loc.format('passport.r.unlocked', {'country': country}),
    };
    final accent = after.level == null ? ColituColors.lilac : levelColor(after.level!);
    return dim(
      0.94,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final burst = _span(t, 0.6, 0.95);
          final appear = _ease(_span(t, 0.08, 0.32));
          // Level-ups turn once around while the new material comes in.
          final spin = levelUp ? _ease(_span(t, 0.2, 0.62)) * 2 * math.pi : 0.0;
          final sweep = _span(t, 0.32, 0.62);
          final words = _span(t, 0.62, 0.8);
          return Stack(
            alignment: Alignment.center,
            children: [
              // Light burst behind the stamp when the material lands.
              if (burst > 0)
                Opacity(
                  opacity: 1 - burst * 0.7,
                  child: CustomPaint(size: const Size(420, 420), painter: _BurstPainter(accent, burst)),
                ),
              SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: appear,
                      child: _perspective(
                        rotateY: spin,
                        scale: 0.82 + 0.18 * appear,
                        child: SizedBox(
                          width: 280,
                          height: 280,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              StampArt(stamp: stamp, progress: before, lockSize: 0),
                              ClipRect(
                                clipper: _SweepClipper(sweep),
                                child: StampArt(stamp: stamp, progress: after, lockSize: 0),
                              ),
                              if (sweep > 0.01 && sweep < 0.99) CustomPaint(painter: _GlintPainter(sweep)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Opacity(
                      opacity: words,
                      child: Transform.translate(
                        offset: Offset(0, (1 - words) * 24),
                        child: Transform.scale(
                          scale: 1.12 - 0.12 * words,
                          child: Column(
                            children: [
                              Text(kicker, style: ColituText.kicker.copyWith(color: accent)),
                              const SizedBox(height: 8),
                              Text(
                                title.toUpperCase(),
                                textAlign: TextAlign.center,
                                style: ColituText.display.copyWith(fontSize: 30, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '$country · ${loc.format('passport.stampNo', {'n': stampNumber(stamp)})}',
                                textAlign: TextAlign.center,
                                style: ColituText.muted.copyWith(color: accent),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    buttons(0.82, [
                      Builder(
                        builder: (button) => ColituButton(
                          label: loc['passport.r.story'],
                          onPressed: () {
                            unawaited(sharePassport(button, stamp: stamp, premium: widget.premium));
                            close();
                          },
                        ),
                      ),
                      ColituButton.secondary(label: loc['passport.r.add'], onPressed: close),
                    ]),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SweepClipper extends CustomClipper<Rect> {
  const _SweepClipper(this.sweep);

  final double sweep;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * sweep, size.height);

  @override
  bool shouldReclip(covariant _SweepClipper old) => old.sweep != sweep;
}

class _GlintPainter extends CustomPainter {
  const _GlintPainter(this.sweep);

  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * sweep;
    final rect = Rect.fromLTWH(x - 40, 0, 52, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.transparent, Colors.white.withValues(alpha: 0.55), Colors.transparent],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _GlintPainter old) => old.sweep != sweep;
}

class _BurstPainter extends CustomPainter {
  const _BurstPainter(this.color, this.burst);

  final Color color;
  final double burst;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final glow = r * (0.4 + burst * 0.6);
    canvas
      ..drawCircle(
        c,
        glow,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: glow)),
      )
      ..drawCircle(
        c,
        r * (0.3 + burst * 0.7),
        Paint()
          ..color = color.withValues(alpha: 0.5 * (1 - burst))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) => old.burst != burst || old.color != color;
}

/// One puzzle piece: a piece flies up into its slot, the slot flashes and the
/// count ticks up. Closes by itself (a tap closes it sooner).
class _PieceReveal extends StatefulWidget {
  const _PieceReveal({required this.event});

  final StampEvent event;

  @override
  State<_PieceReveal> createState() => _PieceRevealState();
}

class _PieceRevealState extends _RevealState<_PieceReveal> {
  @override
  Duration get duration => const Duration(milliseconds: 1800);

  @override
  String get sound => 'piece';

  @override
  double get hitAt => 0.55;

  @override
  void onHit() => PassportEffects.tap();

  // With animations off the card still stays long enough to read.
  @override
  Duration get autoClose => const Duration(milliseconds: 2300);

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final stamp = ColituPassport.stampOf(widget.event.code)!;
    final now = ColituPassport.I.progressOf(stamp.code);
    // The slot this piece fills, counted inside its level's puzzle.
    final filled = widget.event.levelPieces.clamp(1, StampProgress.pieceCount);
    final base = math.max(0, now.pieces - 1) ~/ StampProgress.pieceCount * StampProgress.pieceCount;
    final before = now.copyWith(pieces: base + filled - 1);
    final after = now.copyWith(pieces: base + filled - (filled == StampProgress.pieceCount ? 1 : 0));
    final level = before.level ?? StampLevel.bronze;
    final color = levelColor(level);
    return dim(
      0.86,
      onTap: close,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final landed = t >= 0.55;
          final pop = _span(t, 0.55, 0.75);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: _span(t, 0, 0.15),
                child: SizedBox(
                  width: 260,
                  height: 260,
                  child: Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.none,
                    children: [
                      StampArt(stamp: stamp, progress: landed ? after : before, lockSize: 0, puzzle: true),
                      CustomPaint(painter: _FlyingPiecePainter(t, pieceSlot(filled), color)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Opacity(
                opacity: pop,
                child: Transform.scale(
                  scale: 0.8 + 0.2 * pop,
                  child: Column(
                    children: [
                      Text(
                        loc['passport.r.piece'],
                        style: ColituText.display.copyWith(fontSize: 34, fontWeight: FontWeight.w700, color: color),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${loc.countryName(stamp.code)} · ${levelName(level)} · ${loc.format('passport.pieces', {'n': filled})}',
                        textAlign: TextAlign.center,
                        style: ColituText.muted,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Opacity(
                opacity: _span(t, 0.8, 1),
                child: Text(loc['passport.r.tap'], style: ColituText.small.copyWith(color: ColituColors.dim)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FlyingPiecePainter extends CustomPainter {
  const _FlyingPiecePainter(this.t, this.index, this.color);

  final double t;
  final int index;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.shortestSide * 0.06;
    final cw = (size.width - inset * 2) / 3;
    final ch = (size.height - inset * 2) / 4;
    final target = Offset(inset + (index % 3) * cw, inset + (index ~/ 3) * ch);
    final fly = _ease(_span(t, 0.12, 0.55));
    if (fly < 1) {
      final start = Offset(size.width / 2 - cw / 2, size.height + 120);
      final pos = Offset.lerp(start, target, fly)!;
      final scale = 1.4 - 0.4 * fly;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(pos.dx - cw * (scale - 1) / 2, pos.dy - ch * (scale - 1) / 2, cw * scale, ch * scale),
          const Radius.circular(6),
        ),
        Paint()..color = color.withValues(alpha: 0.9),
      );
    } else {
      final flash = 1 - _span(t, 0.55, 0.9);
      if (flash <= 0) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(target & Size(cw, ch), const Radius.circular(6)),
        Paint()..color = Colors.white.withValues(alpha: 0.6 * flash),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlyingPiecePainter old) => old.t != t;
}

/// A finished collection set: the seal drops onto the page with a thud, ink
/// rings spread, the screen shakes once; then the set's name and its reward.
class _CollectionReveal extends StatefulWidget {
  const _CollectionReveal({required this.event});

  final StampEvent event;

  @override
  State<_CollectionReveal> createState() => _CollectionRevealState();
}

class _CollectionRevealState extends _RevealState<_CollectionReveal> {
  @override
  Duration get duration => const Duration(milliseconds: 2200);

  @override
  String get sound => 'seal';

  @override
  double get hitAt => 0.34;

  @override
  void onHit() => PassportEffects.thud();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final set = PassportCollection.values.firstWhere((c) => c.id == widget.event.code);
    final color = sealColor(set);
    return dim(
      0.94,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final shakeT = _span(t, 0.34, 0.5);
          final shake = t >= 0.34 && t <= 0.5 ? math.sin(shakeT * 6 * math.pi) * (1 - shakeT) * 10 : 0.0;
          final ink = _span(t, 0.34, 0.8);
          final drop = _ease(_span(t, 0.08, 0.34));
          final words = _span(t, 0.55, 0.75);
          return Transform.translate(
            offset: Offset(shake, 0),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (ink > 0)
                  Opacity(
                    opacity: 1 - ink,
                    child: CustomPaint(size: const Size(380, 380), painter: _InkPainter(color, ink)),
                  ),
                SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Falls from big and transparent to its size: the stamp hitting paper.
                      Opacity(
                        opacity: drop,
                        child: Transform.scale(
                          scale: 2.6 - 1.6 * drop,
                          child: PassportSeal(collection: set, earned: true, size: 220),
                        ),
                      ),
                      const SizedBox(height: 26),
                      Opacity(
                        opacity: words,
                        child: Column(
                          children: [
                            Text(loc['passport.r.setDone'], style: ColituText.kicker.copyWith(color: color)),
                            const SizedBox(height: 8),
                            Text(
                              set.title.toUpperCase(),
                              textAlign: TextAlign.center,
                              style: ColituText.display.copyWith(fontSize: 30, fontWeight: FontWeight.w700),
                            ),
                            if (set.cover != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                loc.format('passport.r.newCover', {'cover': coverName(set.cover!)}),
                                textAlign: TextAlign.center,
                                style: ColituText.muted.copyWith(color: color),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      buttons(0.8, [
                        if (set.cover != null)
                          ColituButton(
                            label: loc['passport.r.useCover'],
                            onPressed: () {
                              ColituPassport.I.goals.updateCover(set.cover);
                              close();
                            },
                          ),
                        ColituButton.secondary(label: loc['passport.r.great'], onPressed: close),
                      ]),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _InkPainter extends CustomPainter {
  const _InkPainter(this.color, this.ink);

  final Color color;
  final double ink;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas
      ..drawCircle(
        c,
        r * (0.35 + 0.65 * ink),
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      )
      ..drawCircle(
        c,
        r * (0.3 + 0.45 * ink),
        Paint()
          ..color = color.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6,
      );
    // Ink drops around the seal.
    final drop = Paint()..color = color.withValues(alpha: 0.6);
    for (var i = 0; i < 10; i++) {
      final a = i * 36 * math.pi / 180;
      final d = r * (0.38 + 0.5 * ink);
      canvas.drawCircle(Offset(c.dx + math.cos(a) * d, c.dy + math.sin(a) * d), 4 - 2 * ink, drop);
    }
  }

  @override
  bool shouldRepaint(covariant _InkPainter old) => old.ink != ink;
}

/// An achievement: a card turns from its "???" back to the badge face, with
/// a few sparks; then the title it gives.
class _AchievementReveal extends StatefulWidget {
  const _AchievementReveal({required this.event});

  final StampEvent event;

  @override
  State<_AchievementReveal> createState() => _AchievementRevealState();
}

class _AchievementRevealState extends _RevealState<_AchievementReveal> {
  @override
  Duration get duration => const Duration(milliseconds: 2200);

  @override
  String get sound => 'level';

  // The card shows its face half-way through the (eased) turn.
  @override
  double get hitAt => 0.28;

  @override
  void onHit() => PassportEffects.confirm();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final ach = PassportAchievement.values.firstWhere((a) => a.id == widget.event.code);
    return dim(
      0.94,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final turn = _ease(_span(t, 0.15, 0.55));
          final spark = _span(t, 0.5, 0.9);
          final words = _span(t, 0.6, 0.8);
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 300,
                  height: 300,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (spark > 0)
                        Opacity(
                          opacity: 1 - spark,
                          child: CustomPaint(size: const Size(300, 300), painter: _SparkPainter(spark)),
                        ),
                      Opacity(
                        opacity: _span(t, 0, 0.15),
                        child: _perspective(
                          rotateY: math.pi * (1 - turn),
                          child: Container(
                            width: 190,
                            height: 240,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xFF2A2468), Color(0xFF15133A)],
                              ),
                              border: Border.all(color: ColituColors.lilac.withValues(alpha: 0.7), width: 1.5),
                            ),
                            alignment: Alignment.center,
                            child: turn < 0.5
                                ? Text('???', style: ColituText.display.copyWith(fontSize: 40, color: ColituColors.dim))
                                : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        AchievementBadge(achievement: ach, earned: true, size: 96),
                                        const SizedBox(height: 16),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12),
                                          child: Text(ach.title, textAlign: TextAlign.center, style: ColituText.label),
                                        ),
                                      ],
                                    ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Opacity(
                  opacity: words,
                  child: Column(
                    children: [
                      Text(
                        ach.secret ? loc['passport.r.secretAch'] : loc['passport.r.ach'],
                        style: ColituText.kicker.copyWith(color: ColituColors.lilac),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        ach.title.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: ColituText.display.copyWith(fontSize: 28, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(loc['passport.ach.${ach.id}'], textAlign: TextAlign.center, style: ColituText.muted),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                buttons(0.8, [
                  ColituButton(
                    label: loc['passport.ach.use'],
                    onPressed: () {
                      ColituPassport.I.goals.updateTitle(ach.id);
                      close();
                    },
                  ),
                  ColituButton.secondary(label: loc['passport.r.great'], onPressed: close),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  const _SparkPainter(this.spark);

  final double spark;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final line = Paint()
      ..color = ColituColors.lilac
      ..strokeWidth = 1.5;
    for (var i = 0; i < 12; i++) {
      final a = i * 30 * math.pi / 180;
      final d = size.shortestSide / 2 * (0.45 + 0.5 * spark);
      final p = Offset(c.dx + math.cos(a) * d, c.dy + math.sin(a) * d);
      canvas
        ..drawLine(p.translate(-6, 0), p.translate(6, 0), line)
        ..drawLine(p.translate(0, -6), p.translate(0, 6), line);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.spark != spark;
}

/// A chapter opens: its name sweeps in over the dimmed page.
class _ChapterReveal extends StatefulWidget {
  const _ChapterReveal({required this.event});

  final StampEvent event;

  @override
  State<_ChapterReveal> createState() => _ChapterRevealState();
}

class _ChapterRevealState extends _RevealState<_ChapterReveal> {
  @override
  Duration get duration => const Duration(milliseconds: 2200);

  @override
  String get sound => 'reveal';

  @override
  double get hitAt => 0.5;

  @override
  void onHit() => PassportEffects.confirm();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final n = widget.event.code;
    return dim(
      0.96,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final glow = _span(t, 0.2, 0.7);
          final words = _ease(_span(t, 0.15, 0.55));
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: glow * (1 - _span(t, 0.8, 1) * 0.5),
                child: Container(
                  width: 420 * (0.5 + glow * 0.5),
                  height: 420 * (0.5 + glow * 0.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [ColituColors.lilac.withValues(alpha: 0.35), ColituColors.lilac.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: words,
                      child: Text(loc['passport.r.chapterOpen'], style: ColituText.kicker.copyWith(color: ColituColors.lilac)),
                    ),
                    const SizedBox(height: 10),
                    Opacity(
                      opacity: words,
                      child: Transform.translate(
                        offset: Offset(0, (1 - words) * 30),
                        child: Text(
                          loc['passport.ch$n'].toUpperCase(),
                          textAlign: TextAlign.center,
                          style: ColituText.display.copyWith(fontSize: 30, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Opacity(
                      opacity: _span(t, 0.55, 0.75),
                      child: Text(loc['passport.r.chapterBody$n'], textAlign: TextAlign.center, style: ColituText.muted),
                    ),
                    const SizedBox(height: 28),
                    buttons(0.8, [ColituButton(label: loc['passport.r.great'], onPressed: close)]),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A weekly expedition done: a visa stamp drops in with a light thud. Closes by itself.
class _ExpeditionReveal extends StatefulWidget {
  const _ExpeditionReveal({required this.event});

  final StampEvent event;

  @override
  State<_ExpeditionReveal> createState() => _ExpeditionRevealState();
}

class _ExpeditionRevealState extends _RevealState<_ExpeditionReveal> {
  @override
  Duration get duration => const Duration(milliseconds: 1600);

  @override
  String? get sound => null;

  @override
  double get hitAt => 0.4;

  @override
  void onHit() => PassportEffects.tap();

  @override
  Duration get autoClose => const Duration(milliseconds: 2600);

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final goal = ExpeditionGoal.values.firstWhere((g) => g.id == widget.event.code);
    return dim(
      0.86,
      onTap: close,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final drop = _ease(_span(t, 0.05, 0.4));
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: drop,
                child: Transform.scale(scale: 2.2 - 1.2 * drop, child: VisaStamp(goal: goal, size: 220)),
              ),
              const SizedBox(height: 24),
              Opacity(
                opacity: _span(t, 0.45, 0.7),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      Text(loc['passport.r.expedition'], style: ColituText.kicker.copyWith(color: ColituColors.lilac)),
                      const SizedBox(height: 6),
                      Text(loc['passport.x.${goal.id}'], textAlign: TextAlign.center, style: ColituText.h2),
                      const SizedBox(height: 4),
                      Text(
                        loc.format('passport.week.total', {'n': ColituPassport.I.weekly.total}),
                        style: ColituText.small.copyWith(color: ColituColors.lilac),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The Companion stamp arrives: it drops in like a seal, then why you got it.
class _SpecialReveal extends StatefulWidget {
  const _SpecialReveal({required this.event});

  final StampEvent event;

  @override
  State<_SpecialReveal> createState() => _SpecialRevealState();
}

class _SpecialRevealState extends _RevealState<_SpecialReveal> {
  @override
  Duration get duration => const Duration(milliseconds: 2200);

  @override
  String get sound => 'seal';

  @override
  double get hitAt => 0.34;

  @override
  void onHit() => PassportEffects.thud();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return dim(
      0.94,
      AnimatedBuilder(
        animation: time,
        builder: (context, _) {
          final drop = _ease(_span(t, 0.08, 0.34));
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: drop,
                  child: Transform.scale(scale: 2.4 - 1.4 * drop, child: const CompanionStamp(earned: true, size: 220)),
                ),
                const SizedBox(height: 24),
                Opacity(
                  opacity: _span(t, 0.5, 0.75),
                  child: Column(
                    children: [
                      Text(loc['passport.r.special'], style: ColituText.kicker.copyWith(color: ColituColors.lilac)),
                      const SizedBox(height: 8),
                      Text(
                        'COMPANION',
                        textAlign: TextAlign.center,
                        style: ColituText.display.copyWith(fontSize: 30, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(loc['passport.companion.body'], textAlign: TextAlign.center, style: ColituText.muted),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                buttons(0.8, [ColituButton(label: loc['passport.r.great'], onPressed: close)]),
              ],
            ),
          );
        },
      ),
    );
  }
}
