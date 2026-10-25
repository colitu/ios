import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

// Drawn pieces of Colitu Passport (Android: PassportScreen.kt StampArt,
// PassportSections.kt covers/seals/badges, PassportReveal.kt CompanionStamp,
// PassportP3.kt VisaStamp): the same art, colours and puzzle.

const passportAssets = 'assets/passport';

/// Countries whose level art ships (`stamp_<code>_<level>.webp`); FI has no silver.
const _levelArt = {'SE', 'FI', 'DE', 'NL', 'GB', 'PL', 'LV', 'FR', 'US', 'JP'};

String stampAsset(String code) => '$passportAssets/stamp_${code.toLowerCase()}.webp';

/// The drawn level art when it ships, else null (the base stamp is tinted).
String? levelAsset(String code, StampLevel? level) {
  if (level == null || !_levelArt.contains(code)) return null;
  if (code == 'FI' && level == StampLevel.silver) return null;
  return '$passportAssets/stamp_${code.toLowerCase()}_${level.key}.webp';
}

String coverAsset(CoverTheme theme) =>
    theme == CoverTheme.classic ? '$passportAssets/passport_cover.webp' : '$passportAssets/passport_cover_${theme.key}.webp';

String sealAsset(PassportCollection c) => '$passportAssets/seal_${c.id}.webp';

String badgeAsset(PassportAchievement a) => '$passportAssets/badge_${a.id}.webp';

const passportBgAsset = '$passportAssets/passport_bg.webp';
const passportSheetBgAsset = '$passportAssets/passport_sheet_bg.webp';
const passportShareBgAsset = '$passportAssets/passport_share_bg.webp';

/// Page background of the passport screens.
const passportInk = Color(0xFF0B0A22);

Color levelColor(StampLevel level) => switch (level) {
  StampLevel.bronze => const Color(0xFFDDA27A),
  StampLevel.silver => const Color(0xFFD3DAE8),
  StampLevel.gold => const Color(0xFFF2C76E),
  StampLevel.diamond => const Color(0xFFC4B5FD),
};

String levelName(StampLevel level) => ColituLoc.I['passport.level.${level.key}'];

/// Effect strength of the live stamp per level; Diamond the most.
double levelIntensity(StampLevel level) => switch (level) {
  StampLevel.bronze => 0.35,
  StampLevel.silver => 0.55,
  StampLevel.gold => 0.75,
  StampLevel.diamond => 1,
};

/// Time spent on a country's servers: "45 dk", "14 sa".
String usedTime(int minutes) => minutes < 60
    ? ColituLoc.I.format('passport.mins', {'n': minutes})
    : ColituLoc.I.format('passport.hours', {'n': minutes ~/ 60});

String stampNumber(ColituStamp stamp) => stamp.number.toString().padLeft(2, '0');

String coverName(CoverTheme theme) => ColituLoc.I['passport.cover.${theme.key}'];

/// Fixed order in which the 12 puzzle pieces fill (row-major indices).
const pieceOrder = [4, 0, 11, 6, 2, 9, 7, 1, 10, 3, 8, 5];

/// Grid index (row-major) of the [filled]-th piece of a puzzle.
int pieceSlot(int filled) => pieceOrder[(filled - 1).clamp(0, pieceOrder.length - 1)];

const identityMatrix = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

/// Luminance mapped onto one material tone (r, g, b gains and offsets).
List<double> tone(double mr, double mg, double mb, double or, double og, double ob) => [
  .3 * mr, .59 * mr, .11 * mr, 0, or, //
  .3 * mg, .59 * mg, .11 * mg, 0, og,
  .3 * mb, .59 * mb, .11 * mb, 0, ob,
  0, 0, 0, 1, 0,
];

/// Grey, darker and slightly cool: the stamp before it is unlocked.
final lockedMatrix = tone(0.5, 0.5, 0.59, 0, 0, 6);

/// Code tint for a level until its drawn art ships; Diamond keeps the violet original.
List<double> materialMatrix(StampLevel? level) => switch (level) {
  StampLevel.bronze => tone(1.2, 0.82, 0.52, 38, 16, 0),
  StampLevel.silver => tone(1.12, 1.16, 1.25, 18, 20, 26),
  StampLevel.gold => tone(1.25, 1.02, 0.42, 48, 30, 0),
  _ => identityMatrix,
};

const greyMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _lerp(List<double> a, List<double> b, double t) => [for (var i = 0; i < 20; i++) a[i] + (b[i] - a[i]) * t];

bool _same(List<double> a, List<double> b) {
  for (var i = 0; i < 20; i++) {
    if ((a[i] - b[i]).abs() > 1e-6) return false;
  }
  return true;
}

/// Live effects run unless the system asks for less motion.
bool motionAllowed(BuildContext context) => !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

/// One stamp: grey and locked, or in its level's material. [puzzle] darkens
/// the pieces still missing on the way to the next level; [live] turns the
/// orbit lines and adds a glint (stronger per level).
class StampArt extends StatefulWidget {
  const StampArt({
    super.key,
    required this.stamp,
    required this.progress,
    this.lockSize = 30,
    this.puzzle = false,
    this.live = false,
    this.size,
  });

  final ColituStamp stamp;
  final StampProgress progress;
  final double lockSize;
  final bool puzzle;
  final bool live;
  final double? size;

  @override
  State<StampArt> createState() => _StampArtState();
}

class _StampArtState extends State<StampArt> with SingleTickerProviderStateMixin {
  AnimationController? _orbit;

  void _sync(bool animate, StampLevel? level) {
    if (!animate) {
      _orbit?.stop();
      return;
    }
    final period = Duration(milliseconds: level == StampLevel.diamond ? 9000 : 14000);
    final orbit = _orbit ??= AnimationController(vsync: this, duration: period);
    if (orbit.duration != period || !orbit.isAnimating) {
      orbit
        ..duration = period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _orbit?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final level = progress.level;
    final code = widget.stamp.code;
    final art = levelAsset(code, level);
    final animate = widget.live && level != null && motionAllowed(context);
    _sync(animate, level);
    final showPuzzle = widget.puzzle && level != null && !progress.mastered;
    final intensity = level == null ? 0.0 : levelIntensity(level);

    final body = TweenAnimationBuilder<double>(
      // Animates when a stamp unlocks while the page is open.
      tween: Tween(end: level != null ? 1 : 0),
      duration: const Duration(milliseconds: 900),
      builder: (context, open, _) {
        final target = art != null ? identityMatrix : materialMatrix(level);
        final matrix = _lerp(lockedMatrix, target, open);
        Widget image = Image.asset(
          art ?? stampAsset(code),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          semanticLabel: ColituLoc.I.countryName(code),
        );
        if (!_same(matrix, identityMatrix)) {
          image = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: image);
        }
        final orbit = animate ? _orbit : null;
        final overlays = showPuzzle || orbit != null;
        if (overlays) {
          image = ColorFiltered(
            // An own layer, so the overlays draw only on the stamp's pixels (srcATop).
            colorFilter: const ColorFilter.matrix(identityMatrix),
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                if (showPuzzle) CustomPaint(painter: _PuzzlePainter(progress.levelPieces)),
                if (orbit != null)
                  AnimatedBuilder(
                    animation: orbit,
                    builder: (context, _) => CustomPaint(
                      painter: _LivePainter(orbit.value * 360, intensity, level == StampLevel.diamond),
                    ),
                  ),
              ],
            ),
          );
        }
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            image,
            if (open < 1 && widget.lockSize > 0)
              Center(
                child: Opacity(
                  opacity: 1 - open,
                  child: Container(
                    width: widget.lockSize,
                    height: widget.lockSize,
                    decoration: BoxDecoration(
                      color: const Color(0xCC14141B),
                      shape: BoxShape.circle,
                      border: Border.all(color: ColituColors.lineStrong),
                    ),
                    child: Icon(CupertinoIcons.lock_fill, size: widget.lockSize * 0.46, color: ColituColors.text),
                  ),
                ),
              ),
          ],
        );
      },
    );
    final square = AspectRatio(aspectRatio: 1, child: body);
    if (widget.size == null) return square;
    return SizedBox(width: widget.size, height: widget.size, child: square);
  }
}

/// 3 × 4 jigsaw over the stamp; missing pieces are shaded.
class _PuzzlePainter extends CustomPainter {
  const _PuzzlePainter(this.filled);

  final int filled;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.shortestSide * 0.06;
    final w = size.width - inset * 2;
    final h = size.height - inset * 2;
    final cw = w / 3;
    final ch = h / 4;
    final done = pieceOrder.take(filled).toSet();
    final shade = Paint()
      ..color = const Color(0xC705040F)
      ..blendMode = BlendMode.srcATop;
    for (var i = 0; i < StampProgress.pieceCount; i++) {
      if (done.contains(i)) continue;
      canvas.drawRect(Rect.fromLTWH(inset + (i % 3) * cw, inset + (i ~/ 3) * ch, cw, ch), shade);
    }
    canvas.drawPath(
      jigsawPath(inset, w, h),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..blendMode = BlendMode.srcATop,
    );
  }

  @override
  bool shouldRepaint(covariant _PuzzlePainter old) => old.filled != filled;
}

Path jigsawPath(double o, double w, double h) {
  final p = Path();
  final cw = w / 3;
  final ch = h / 4;
  final k = math.min(cw, ch) * 0.15;
  for (var i = 1; i < 3; i++) {
    final x = o + cw * i;
    for (var j = 0; j < 4; j++) {
      final y0 = o + ch * j;
      final ym = y0 + ch / 2;
      final d = (i + j) % 2 == 0 ? 1.0 : -1.0;
      p
        ..moveTo(x, y0)
        ..lineTo(x, ym - k)
        ..cubicTo(x + d * k * 2.4, ym - k * 1.9, x + d * k * 2.4, ym + k * 1.9, x, ym + k)
        ..lineTo(x, y0 + ch);
    }
  }
  for (var j = 1; j < 4; j++) {
    final y = o + ch * j;
    for (var i = 0; i < 3; i++) {
      final x0 = o + cw * i;
      final xm = x0 + cw / 2;
      final d = (i + j) % 2 == 0 ? -1.0 : 1.0;
      p
        ..moveTo(x0, y)
        ..lineTo(xm - k, y)
        ..cubicTo(xm - k * 1.9, y + d * k * 2.4, xm + k * 1.9, y + d * k * 2.4, xm + k, y)
        ..lineTo(x0 + cw, y);
    }
  }
  return p;
}

/// Turning orbit lines, a travelling glint and, on Diamond, twinkles. iOS has
/// no tilt sensor in the app, so the glint follows the orbit instead.
class _LivePainter extends CustomPainter {
  const _LivePainter(this.angle, this.intensity, this.diamond);

  final double angle;
  final double intensity;
  final bool diamond;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..blendMode = BlendMode.srcATop;
    void oval(double degrees, Rect rect, Color color) {
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(degrees * math.pi / 180)
        ..translate(-center.dx, -center.dy)
        ..drawOval(rect, stroke..color = color)
        ..restore();
    }

    oval(
      angle,
      Rect.fromLTWH(size.width * 0.06, size.height * 0.33, size.width * 0.88, size.height * 0.34),
      Colors.white.withValues(alpha: 0.26 * intensity),
    );
    oval(
      -angle * 0.6 + 60,
      Rect.fromLTWH(size.width * 0.16, size.height * 0.38, size.width * 0.68, size.height * 0.24),
      const Color(0xFFC4B5FD).withValues(alpha: 0.22 * intensity),
    );
    final rad = angle * math.pi / 180;
    final cx = size.width * (0.5 + math.sin(rad) * 0.35);
    final cy = size.height * (0.5 + math.cos(rad) * 0.35);
    final r = size.shortestSide * 0.5;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.srcATop
        ..shader = LinearGradient(
          colors: [Colors.transparent, Colors.white.withValues(alpha: 0.34 * intensity), Colors.transparent],
        ).createShader(Rect.fromPoints(Offset(cx - r, cy - r), Offset(cx + r, cy + r))),
    );
    if (diamond) {
      const spots = [(0.22, 0.28), (0.74, 0.2), (0.82, 0.62), (0.3, 0.74), (0.55, 0.45), (0.62, 0.84)];
      for (var i = 0; i < spots.length; i++) {
        final s = (math.sin(rad * 4 + i * 1.7) + 1) / 2;
        final a = s * s;
        final c = Offset(size.width * spots[i].$1, size.height * spots[i].$2);
        final len = 6 * a;
        final line = Paint()
          ..color = Colors.white.withValues(alpha: a)
          ..strokeWidth = 1.2
          ..blendMode = BlendMode.srcATop;
        canvas
          ..drawLine(Offset(c.dx - len, c.dy), Offset(c.dx + len, c.dy), line)
          ..drawLine(Offset(c.dx, c.dy - len), Offset(c.dx, c.dy + len), line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LivePainter old) => old.angle != angle || old.intensity != intensity;
}

/// The passport cover in [theme] (720 × 900 art).
class PassportCover extends StatelessWidget {
  const PassportCover({super.key, required this.theme, required this.height});

  final CoverTheme theme;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: height * 720 / 900,
      child: Image.asset(coverAsset(theme), fit: BoxFit.contain, gaplessPlayback: true),
    );
  }
}

Color sealColor(PassportCollection c) => switch (c) {
  PassportCollection.nordic => const Color(0xFF7FD6E0),
  PassportCollection.baltic => const Color(0xFFE8B067),
  PassportCollection.atlantic => const Color(0xFF8FB2FF),
  PassportCollection.heart => const Color(0xFFC4B5FD),
  PassportCollection.pacific => const Color(0xFFFFA98A),
  PassportCollection.goldRush => const Color(0xFFF2C76E),
};

/// Ink seal of a collection; grey until earned, a hidden set stays "?".
class PassportSeal extends StatelessWidget {
  const PassportSeal({super.key, required this.collection, required this.earned, required this.size});

  final PassportCollection collection;
  final bool earned;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (earned || !collection.secret) {
      Widget image = Image.asset(sealAsset(collection), width: size, height: size, semanticLabel: collection.title);
      if (!earned) {
        image = Opacity(opacity: 0.4, child: ColorFiltered(colorFilter: const ColorFilter.matrix(greyMatrix), child: image));
      }
      return image;
    }
    return SizedBox(
      width: size,
      height: size,
      child: Transform.rotate(
        angle: -12 * math.pi / 180,
        child: Opacity(
          opacity: 0.6,
          child: CustomPaint(
            painter: _RingPainter(ColituColors.dim),
            child: Center(
              child: Text('?', style: ColituText.h1.copyWith(color: ColituColors.dim)),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(
      c,
      r - 2,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    final dash = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final inner = r - 7;
    final steps = (2 * math.pi * inner / 8).floor();
    for (var i = 0; i < steps; i++) {
      final a0 = i / steps * 2 * math.pi;
      canvas.drawArc(Rect.fromCircle(center: c, radius: inner), a0, (5 / 8) * 2 * math.pi / steps, false, dash);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.color != color;
}

IconData achievementIcon(PassportAchievement a) => switch (a) {
  PassportAchievement.first => CupertinoIcons.star_fill,
  PassportAchievement.globetrotter => CupertinoIcons.globe,
  PassportAchievement.origin => CupertinoIcons.checkmark_seal_fill,
  PassportAchievement.nordicMaster => CupertinoIcons.checkmark_shield_fill,
  PassportAchievement.night => CupertinoIcons.eye_fill,
  PassportAchievement.early => CupertinoIcons.bolt_fill,
  PassportAchievement.longHaul => CupertinoIcons.power,
  PassportAchievement.diamond => CupertinoIcons.star_fill,
  PassportAchievement.pathfinder => CupertinoIcons.arrow_up_right,
  PassportAchievement.legacyGold => CupertinoIcons.checkmark_seal_fill,
  PassportAchievement.legacyDiamond => CupertinoIcons.checkmark_seal_fill,
};

/// An achievement's badge; grey until earned, a secret one stays "?".
class AchievementBadge extends StatelessWidget {
  const AchievementBadge({super.key, required this.achievement, required this.earned, required this.size});

  final PassportAchievement achievement;
  final bool earned;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hidden = achievement.secret && !earned;
    if (!hidden) {
      Widget image = Image.asset(badgeAsset(achievement), width: size, height: size, semanticLabel: achievement.title);
      if (!earned) {
        image = Opacity(opacity: 0.35, child: ColorFiltered(colorFilter: const ColorFilter.matrix(greyMatrix), child: image));
      }
      return image;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ColituColors.surface2,
        shape: BoxShape.circle,
        border: Border.all(color: ColituColors.lineStrong, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text('?', style: ColituText.h2.copyWith(color: ColituColors.dim)),
    );
  }
}

/// The Companion stamp: two linked holders in a lilac frame.
class CompanionStamp extends StatelessWidget {
  const CompanionStamp({super.key, required this.earned, required this.size});

  final bool earned;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = earned ? ColituColors.lilac : ColituColors.dim;
    return Opacity(
      opacity: earned ? 1 : 0.35,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _FramePainter(color),
          child: Center(
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.person_fill, size: 22, color: color),
                        Icon(CupertinoIcons.person_fill, size: 22, color: color),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('COMPANION', style: ColituText.kicker.copyWith(fontSize: 9, letterSpacing: 1, color: color)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  const _FramePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.shortestSide * 0.1;
    final rect = Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2);
    canvas
      ..drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), Paint()..color = const Color(0xFF1B1840))
      ..drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(rect.deflate(6), const Radius.circular(3)),
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
  }

  @override
  bool shouldRepaint(covariant _FramePainter old) => old.color != color;
}

IconData expeditionIcon(ExpeditionGoal goal) => switch (goal) {
  ExpeditionGoal.newCountry => CupertinoIcons.globe,
  ExpeditionGoal.share => CupertinoIcons.paperplane_fill,
  ExpeditionGoal.customize => CupertinoIcons.person_fill,
  ExpeditionGoal.days10 => CupertinoIcons.power,
  ExpeditionGoal.setStamp => CupertinoIcons.square_grid_2x2_fill,
  ExpeditionGoal.pieces => CupertinoIcons.star_fill,
};

/// A dated visa stamp for a finished expedition.
class VisaStamp extends StatelessWidget {
  const VisaStamp({super.key, required this.goal, required this.size});

  final ExpeditionGoal goal;
  final double size;

  @override
  Widget build(BuildContext context) {
    const color = ColituColors.lilac;
    return Transform.rotate(
      angle: -8 * math.pi / 180,
      child: SizedBox(
        width: size,
        height: size * 0.66,
        child: CustomPaint(
          painter: const _VisaPainter(color),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ColituLoc.I['passport.week.visa'],
                  style: ColituText.kicker.copyWith(fontSize: size * 0.07, fontWeight: FontWeight.w700, color: color),
                ),
                Icon(expeditionIcon(goal), size: size * 0.16, color: color),
                Text(
                  ColituPassport.I.weekly.weekKey(),
                  style: ColituText.small.copyWith(fontSize: size * 0.06, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VisaPainter extends CustomPainter {
  const _VisaPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(outer.deflate(1.5), const Radius.circular(10)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final inner = RRect.fromRectAndRadius(outer.deflate(7), const Radius.circular(6));
    final dash = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final metric = (Path()..addRRect(inner)).computeMetrics().first;
    for (var d = 0.0; d < metric.length; d += 10) {
      canvas.drawPath(metric.extractPath(d, math.min(d + 6, metric.length)), dash);
    }
  }

  @override
  bool shouldRepaint(covariant _VisaPainter old) => old.color != color;
}

/// Twelve short segments: the level's puzzle as a bar.
class SegmentBar extends StatelessWidget {
  const SegmentBar({super.key, required this.filled, required this.color});

  final int filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < StampProgress.pieceCount; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: i < filled ? color : ColituColors.glass10,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A thin progress bar with the accent gradient (or [color]).
class PassportBar extends StatelessWidget {
  const PassportBar({super.key, required this.fraction, this.height = 4, this.color});

  final double fraction;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: ColituColors.glass10),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  gradient: color == null ? ColituGradients.accent : null,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Night Explorer · Collector #048213", or the nickname first when set.
String identityLine() {
  final goals = ColituPassport.I.goals;
  return [
    if (goals.nickname.trim().isNotEmpty) goals.nickname,
    ?goals.titleOf(goals.title),
    ColituLoc.I.format('passport.id.collector', {'n': goals.collectorNo}),
  ].join(' · ');
}

enum GoalKind { today, level, done }

/// The nearest reward and how close it is.
class NextGoal {
  const NextGoal(this.text, this.fraction, this.icon, {this.kind = GoalKind.done, this.code, this.target, this.left = 0});

  final String text;
  final double fraction;
  final IconData icon;
  final GoalKind kind;
  final String? code;
  final String? target;
  final int left;
}

/// Today's next piece while one is still open, else the stamp closest to
/// its next level.
NextGoal nextGoal() {
  final loc = ColituLoc.I;
  final p = ColituPassport.I;
  final (minutes, pieces) = p.today;
  // Today's piece only once the server reported today.
  if (p.todayKnown && !p.tester && pieces < ColituPassport.pieceMinutes.length) {
    final next = ColituPassport.pieceMinutes[pieces];
    if (minutes < next) {
      return NextGoal(
        loc.format('passport.goal.today', {'n': next - minutes}),
        minutes / next,
        CupertinoIcons.star_fill,
        kind: GoalKind.today,
        left: next - minutes,
      );
    }
  }
  MapEntry<String, StampProgress>? best;
  for (final e in p.progress.entries) {
    if (e.value.mastered) continue;
    if (best == null || e.value.toNext < best.value.toNext) best = e;
  }
  final level = best?.value.level;
  if (best == null || level == null) {
    if (p.progress.isEmpty) return NextGoal(loc['passport.goal.first'], 0, CupertinoIcons.star_fill);
    // "Today's pieces are collected" only when the server said so.
    if (p.todayKnown && (p.tester || pieces >= ColituPassport.pieceMinutes.length)) {
      return NextGoal(loc['passport.goal.done'], 1, CupertinoIcons.checkmark);
    }
    return NextGoal(loc['passport.goal.mastered'], 1, CupertinoIcons.checkmark);
  }
  final target = level == StampLevel.diamond ? levelName(level) : levelName(StampLevel.values[level.index + 1]);
  return NextGoal(
    loc.format('passport.goal.level', {'country': loc.countryName(best.key), 'level': target, 'n': best.value.toNext}),
    best.value.levelPieces / StampProgress.pieceCount,
    CupertinoIcons.arrow_up,
    kind: GoalKind.level,
    code: best.key,
    target: target,
    left: best.value.toNext,
  );
}

/// The goal line of the home card.
String passportGoalLine() {
  if (ColituPassport.I.count == 0) return ColituLoc.I['passport.goal.first'];
  return nextGoal().text;
}

/// Ring with a sweep gradient: how close the next goal is.
class GoalRing extends StatelessWidget {
  const GoalRing({super.key, required this.fraction, required this.size, required this.stroke, required this.child});

  final double fraction;
  final double size;
  final double stroke;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction),
      duration: const Duration(milliseconds: 700),
      builder: (context, value, _) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingProgressPainter(value, stroke),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RingProgressPainter extends CustomPainter {
  const _RingProgressPainter(this.fraction, this.stroke);

  final double fraction;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      Paint()
        ..color = ColituColors.glass10
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      Paint()
        ..shader = const SweepGradient(
          colors: [Color(0xFFB4A4FF), Color(0xFF8B78FF), Color(0xFFB4A4FF)],
          transform: GradientRotation(-math.pi / 2),
        ).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _RingProgressPainter old) => old.fraction != fraction;
}

/// Colitu Passport entry on the home page: cover, the nearest goal, the count.
class PassportCard extends StatelessWidget {
  const PassportCard({super.key, required this.premium, required this.onOpen});

  final bool premium;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final p = ColituPassport.I;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => Semantics(
        button: true,
        child: ColituPanel(
          key: const ValueKey('passportCard'),
          onTap: onOpen,
          radius: ColituRadius.md,
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          child: Row(
            children: [
              PassportCover(theme: p.goals.activeCover(premium), height: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loc['passport.title'], style: ColituText.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      passportGoalLine(),
                      style: ColituText.small.copyWith(color: ColituColors.lilac),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text('${p.count}/${ColituPassport.stamps.length}', style: ColituText.label.copyWith(color: ColituColors.lilac)),
              const SizedBox(width: 6),
              const Icon(CupertinoIcons.chevron_right, size: 16, color: ColituColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
