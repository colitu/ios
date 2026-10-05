import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:colitu_vpn/colitu/brand/brand_paths.dart';

/// Colitu design system for the phone: near-black surfaces, lavender accent,
/// soft glass cards and pill controls. Typography is "Colitu Sans" (Inter).
abstract final class ColituColors {
  static const bg = Color(0xFF0A0A0E);
  static const bg2 = Color(0xFF0F0F15);
  static const navy = Color(0xFF14141B);
  static const surface = Color(0xFF15151C);
  static const surface2 = Color(0xFF1C1C25);
  static const blue = Color(0xFF7C6CF0);
  static const blue2 = Color(0xFF9483FF);
  static const violet = Color(0xFF9F8CFF);
  static const violet2 = Color(0xFFB4A4FF);
  static const lilac = Color(0xFFC4B5FD);
  static const pink = Color(0xFFE2D6FF);
  static const success = Color(0xFF5EE0A0);
  static const warning = Color(0xFFF5C36B);
  static const danger = Color(0xFFFF6B7A);

  static const text = Color(0xFFF4F3FA);
  static const muted = Color(0xFF9A9AAB);
  static const dim = Color(0xFF63636F);
  static const line = Color(0x14FFFFFF);
  static const lineStrong = Color(0x26FFFFFF);
  static const field = Color(0xFF15151C);
  static const fieldFocus = Color(0xFF1A1A23);
  static const glass06 = Color(0x0FFFFFFF);
  static const glass10 = Color(0x1AFFFFFF);

  /// Brand accent used for primary controls.
  static const accent = violet;
  static const onAccent = Color(0xFF0B0A14);
}

abstract final class ColituGradients {
  /// Card body: a whisper lighter at the top.
  static const panel = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF191921), Color(0xFF131319)],
  );
  static const panelEdge = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x33FFFFFF), Color(0x0AFFFFFF), Color(0x14FFFFFF)],
  );
  static const accent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFC4B5FD), Color(0xFF9F8CFF), Color(0xFF7C6CF0)],
  );
  static const badge = LinearGradient(
    colors: [Color(0xFFB4A4FF), Color(0xFF8B78FF)],
  );
  static const activeOption = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFB4A4FF), Color(0xFF9483FF)],
  );
}

abstract final class ColituRadius {
  static const sm = 14.0;
  static const md = 20.0;
  static const lg = 28.0;
  static const pill = 999.0;
}

abstract final class ColituText {
  static const family = 'Colitu Sans';

  static const kicker = TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.2,
    color: ColituColors.muted,
    height: 1.2,
  );
  static const display = TextStyle(
    fontFamily: family,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.0,
    color: ColituColors.text,
    height: 1.12,
  );
  static const h1 = TextStyle(
    fontFamily: family,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    color: ColituColors.text,
    height: 1.18,
  );
  static const h2 = TextStyle(
    fontFamily: family,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: ColituColors.text,
    height: 1.25,
  );
  static const body = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: ColituColors.text,
    height: 1.5,
  );
  static const muted = TextStyle(
    fontFamily: family,
    fontSize: 14.5,
    fontWeight: FontWeight.w400,
    color: ColituColors.muted,
    height: 1.5,
  );
  static const small = TextStyle(
    fontFamily: family,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    color: ColituColors.muted,
    height: 1.35,
  );
  static const label = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: ColituColors.text,
    height: 1.3,
  );
}

abstract final class ColituTheme {
  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: ColituText.family,
    );
    return base.copyWith(
      scaffoldBackgroundColor: ColituColors.bg,
      canvasColor: ColituColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: ColituColors.violet,
        secondary: ColituColors.lilac,
        surface: ColituColors.surface,
        error: ColituColors.danger,
        onPrimary: ColituColors.onAccent,
        onSurface: ColituColors.text,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: ColituColors.lilac,
        selectionColor: Color(0x559F8CFF),
        selectionHandleColor: ColituColors.violet,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: ColituColors.text,
        elevation: 0,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xF21B1B24),
        contentTextStyle: ColituText.body,
      ),
      dividerColor: ColituColors.line,
      textTheme: base.textTheme.apply(
        bodyColor: ColituColors.text,
        displayColor: ColituColors.text,
        fontFamily: ColituText.family,
      ),
      cupertinoOverrideTheme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: ColituColors.violet,
      ),
    );
  }
}

// ── Backdrop and scaffold ──────────────────────────────────────────────────

/// Near-black background with a hex dot grid fading out from the top and a
/// soft lavender glow behind the top of the page.
class ColituBackdrop extends StatelessWidget {
  const ColituBackdrop({super.key, required this.child, this.glow = true});

  final Widget child;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ColituColors.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _HexDotsPainter(glow: glow)),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _HexDotsPainter extends CustomPainter {
  const _HexDotsPainter({required this.glow});

  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    if (glow) {
      final center = Offset(size.width * 0.5, -size.height * 0.05);
      final radius = size.width * 0.95;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = const RadialGradient(
            colors: [Color(0x449F8CFF), Color(0x149F8CFF), Color(0x00000000)],
            stops: [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    const step = 18.0;
    final rowHeight = step * 0.866;
    final fadeFrom = size.height * 0.05;
    final fadeTo = size.height * 0.62;
    final dot = Paint()..color = Colors.white;
    var row = 0;
    for (var y = 6.0; y < fadeTo; y += rowHeight, row++) {
      final t = ((y - fadeFrom) / (fadeTo - fadeFrom)).clamp(0.0, 1.0);
      final alpha = (0.16 * (1 - t) * (1 - t)).clamp(0.0, 1.0);
      if (alpha < 0.008) break;
      dot.color = Colors.white.withValues(alpha: alpha);
      final offset = row.isOdd ? step / 2 : 0.0;
      for (var x = offset; x < size.width + step; x += step) {
        canvas.drawCircle(Offset(x, y), 0.9, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HexDotsPainter oldDelegate) =>
      oldDelegate.glow != glow;
}

class ColituScaffold extends StatelessWidget {
  const ColituScaffold({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 20),
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
    this.safeBottom = true,
    this.glow = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;
  final bool safeBottom;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColituColors.bg,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      extendBody: true,
      bottomNavigationBar: bottomNavigationBar,
      body: ColituBackdrop(
        glow: glow,
        child: SafeArea(
          bottom: safeBottom,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

// ── Panels ─────────────────────────────────────────────────────────────────

/// Glass card: soft dark body, lit hairline edge, optional lavender glow.
class ColituPanel extends StatelessWidget {
  const ColituPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = ColituRadius.lg,
    this.onTap,
    this.glow = false,
    this.color,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final bool glow;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final panel = Container(
      decoration: BoxDecoration(
        gradient: ColituGradients.panelEdge,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow
            ? const [
                BoxShadow(
                  color: Color(0x559F8CFF),
                  blurRadius: 48,
                  offset: Offset(0, 16),
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ],
      ),
      padding: const EdgeInsets.all(1),
      child: Container(
        decoration: BoxDecoration(
          color: color,
          gradient: color == null ? ColituGradients.panel : null,
          borderRadius: BorderRadius.circular(radius - 1),
        ),
        padding: padding,
        child: child,
      ),
    );
    if (onTap == null) return panel;
    return ColituPressable(onTap: onTap, child: panel);
  }
}

/// Flat tile inside a panel or list; highlighted when active.
class ColituTile extends StatelessWidget {
  const ColituTile({
    super.key,
    required this.child,
    this.onTap,
    this.active = false,
    this.padding = const EdgeInsets.all(14),
    this.radius = ColituRadius.md,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool active;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: active ? const Color(0x1F9F8CFF) : ColituColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: active ? const Color(0x669F8CFF) : ColituColors.line,
        ),
      ),
      child: child,
    );
    if (onTap == null) return tile;
    return ColituPressable(onTap: onTap, child: tile);
  }
}

/// Scale-on-press wrapper used by every tappable surface.
class ColituPressable extends StatefulWidget {
  const ColituPressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<ColituPressable> createState() => _ColituPressableState();
}

class _ColituPressableState extends State<ColituPressable> {
  var _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

// ── Buttons ────────────────────────────────────────────────────────────────

enum ColituButtonKind { primary, secondary, danger }

/// Pill button: lavender (primary), dark glass (secondary) or rose glass
/// (danger).
class ColituButton extends StatelessWidget {
  const ColituButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = ColituButtonKind.primary,
    this.loading = false,
    this.icon,
    this.expand = true,
    this.height = 56,
  });

  const ColituButton.secondary({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.icon,
    this.expand = true,
    this.height = 52,
  }) : kind = ColituButtonKind.secondary;

  const ColituButton.danger({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.icon,
    this.expand = true,
    this.height = 52,
  }) : kind = ColituButtonKind.danger;

  final String label;
  final VoidCallback? onPressed;
  final ColituButtonKind kind;
  final bool loading;
  final IconData? icon;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final (
      Gradient? gradient,
      Color? bg,
      Color fg,
      Border? border,
      List<BoxShadow> shadow,
    ) = switch (kind) {
      ColituButtonKind.primary => (
        ColituGradients.accent,
        null,
        ColituColors.onAccent,
        null,
        const [
          BoxShadow(
            color: Color(0x669F8CFF),
            blurRadius: 30,
            offset: Offset(0, 10),
          ),
        ],
      ),
      ColituButtonKind.secondary => (
        null,
        ColituColors.surface2,
        ColituColors.text,
        Border.all(color: ColituColors.lineStrong),
        const <BoxShadow>[],
      ),
      ColituButtonKind.danger => (
        null,
        const Color(0x22FF6B7A),
        const Color(0xFFFFA3AE),
        Border.all(color: const Color(0x55FF6B7A)),
        const <BoxShadow>[],
      ),
    };
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
          )
        else ...[
          if (icon != null) ...[
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ColituText.label.copyWith(color: fg, fontSize: 15.5),
            ),
          ),
        ],
      ],
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: ColituPressable(
        onTap: enabled ? onPressed : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: enabled || loading ? 1 : 0.5,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(
              gradient: gradient,
              color: bg,
              border: border,
              borderRadius: BorderRadius.circular(ColituRadius.pill),
              boxShadow: enabled ? shadow : const [],
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

class ColituLinkButton extends StatelessWidget {
  const ColituLinkButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.color = ColituColors.lilac,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColituPressable(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: ColituText.small.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Round glass icon button (nav corners, steppers).
class ColituIconButton extends StatelessWidget {
  const ColituIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 44,
    this.accent = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool accent;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: ColituPressable(
        onTap: onPressed,
        scale: 0.92,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: accent ? ColituGradients.accent : null,
            color: accent ? null : ColituColors.surface2,
            shape: BoxShape.circle,
            border: accent ? null : Border.all(color: ColituColors.lineStrong),
            boxShadow: accent
                ? const [
                    BoxShadow(
                      color: Color(0x559F8CFF),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: size * 0.44,
            color: accent ? ColituColors.onAccent : ColituColors.text,
          ),
        ),
      ),
    );
  }
}

// ── Small pieces ───────────────────────────────────────────────────────────

class ColituKicker extends StatelessWidget {
  const ColituKicker(this.text, {super.key, this.color = ColituColors.muted});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: ColituText.kicker.copyWith(color: color),
    );
  }
}

enum ColituBadgeTone { accent, success, warning, danger, neutral }

class ColituBadge extends StatelessWidget {
  const ColituBadge(this.text, {super.key, this.tone = ColituBadgeTone.accent});

  final String text;
  final ColituBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final (Gradient? gradient, Color? bg, Color fg) = switch (tone) {
      ColituBadgeTone.accent => (
        ColituGradients.badge,
        null,
        ColituColors.onAccent,
      ),
      ColituBadgeTone.success => (
        null,
        const Color(0x265EE0A0),
        ColituColors.success,
      ),
      ColituBadgeTone.warning => (
        null,
        const Color(0x26F5C36B),
        ColituColors.warning,
      ),
      ColituBadgeTone.danger => (
        null,
        const Color(0x26FF6B7A),
        ColituColors.danger,
      ),
      ColituBadgeTone.neutral => (
        null,
        ColituColors.glass10,
        ColituColors.text,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        gradient: gradient,
        color: bg,
        borderRadius: BorderRadius.circular(ColituRadius.pill),
      ),
      child: Text(
        text.toUpperCase(),
        style: ColituText.kicker.copyWith(
          color: fg,
          fontSize: 10.5,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Small status pill with a pulsing dot.
class ColituStatusChip extends StatelessWidget {
  const ColituStatusChip({
    super.key,
    required this.text,
    required this.color,
    this.pulsing = false,
  });

  final String text;
  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
      decoration: BoxDecoration(
        color: ColituColors.surface2,
        borderRadius: BorderRadius.circular(ColituRadius.pill),
        border: Border.all(color: ColituColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ColituPulseDot(color: color, pulsing: pulsing),
          const SizedBox(width: 8),
          Text(
            text,
            style: ColituText.small.copyWith(
              color: ColituColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class ColituPulseDot extends StatefulWidget {
  const ColituPulseDot({
    super.key,
    required this.color,
    required this.pulsing,
    this.size = 8,
  });

  final Color color;
  final bool pulsing;
  final double size;

  @override
  State<ColituPulseDot> createState() => _ColituPulseDotState();
}

class _ColituPulseDotState extends State<ColituPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant ColituPulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final glow = widget.pulsing ? 0.4 + 0.6 * _controller.value : 0.8;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: glow),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}

class ColituSpinner extends StatelessWidget {
  const ColituSpinner({
    super.key,
    this.size = 22,
    this.color = ColituColors.lilac,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: 2.2, color: color),
    );
  }
}

/// Round flag well, like the country rows in the reference design.
/// Round country flag from the bundled flag images (assets/flags, square
/// flag-icons renders), centred in its circle. Emoji flags render
/// differently per font and not at all in some, so they are not used.
class ColituFlag extends StatelessWidget {
  const ColituFlag(this.countryCode, {super.key, this.size = 44});

  /// ISO 3166-1 alpha-2 code; "UK" is accepted for Great Britain.
  final String countryCode;
  final double size;

  static String? assetFor(String countryCode) {
    var code = countryCode.trim().toLowerCase();
    if (code == 'uk') code = 'gb';
    return RegExp(r'^[a-z]{2}$').hasMatch(code) ? 'assets/flags/$code.png' : null;
  }

  @override
  Widget build(BuildContext context) {
    final asset = assetFor(countryCode);
    final globe = Icon(CupertinoIcons.globe, size: size * 0.55, color: ColituColors.muted);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ColituColors.surface2,
        shape: BoxShape.circle,
        border: Border.all(color: ColituColors.lineStrong),
      ),
      child: asset == null
          ? globe
          : ClipOval(
              child: Image.asset(
                asset,
                width: size,
                height: size,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => globe,
              ),
            ),
    );
  }
}

/// Round icon well with a lavender tint (feature rows, stat tiles).
class ColituRoundIcon extends StatelessWidget {
  const ColituRoundIcon(
    this.icon, {
    super.key,
    this.size = 40,
    this.accent = false,
  });

  final IconData icon;
  final double size;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: accent ? ColituGradients.accent : null,
        color: accent ? null : ColituColors.surface2,
        shape: BoxShape.circle,
        border: accent ? null : Border.all(color: ColituColors.line),
      ),
      child: Icon(
        icon,
        size: size * 0.46,
        color: accent ? ColituColors.onAccent : ColituColors.lilac,
      ),
    );
  }
}

/// Segmented control: sliding lavender pill.
class ColituSegment<T> extends StatelessWidget {
  const ColituSegment({
    super.key,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.labelOf,
    this.height = 40,
  });

  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final String Function(T value) labelOf;
  final double height;

  @override
  Widget build(BuildContext context) {
    final index = math.max(0, values.indexOf(selected));
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ColituColors.surface,
        borderRadius: BorderRadius.circular(ColituRadius.pill),
        border: Border.all(color: ColituColors.line),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / values.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: width * index,
                top: 0,
                bottom: 0,
                width: width,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: ColituGradients.activeOption,
                    borderRadius: BorderRadius.circular(ColituRadius.pill),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final value in values)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(value),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: ColituText.label.copyWith(
                              fontSize: 13.5,
                              color: value == selected
                                  ? ColituColors.onAccent
                                  : ColituColors.muted,
                            ),
                            child: Text(
                              labelOf(value),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Filter chip (locations).
class ColituChip extends StatelessWidget {
  const ColituChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ColituPressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          gradient: selected ? ColituGradients.activeOption : null,
          color: selected ? null : ColituColors.surface2,
          borderRadius: BorderRadius.circular(ColituRadius.pill),
          border: Border.all(
            color: selected ? Colors.transparent : ColituColors.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 18,
                color: selected ? ColituColors.onAccent : ColituColors.text,
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: ColituText.label.copyWith(
                fontSize: 13.5,
                color: selected ? ColituColors.onAccent : ColituColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Setting row: icon well, title, hint and a switch (or a custom trailing).
class ColituSwitchRow extends StatelessWidget {
  const ColituSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    required this.value,
    this.onChanged,
    this.trailing,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? trailing;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return ColituTile(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      child: Row(
        children: [
          ColituRoundIcon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ColituText.label),
                if (hint != null && hint!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(hint!, style: ColituText.small),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (badge != null) ...[badge!, const SizedBox(width: 8)],
          trailing ??
              CupertinoSwitch(
                value: value,
                onChanged: onChanged,
                activeTrackColor: ColituColors.violet,
              ),
        ],
      ),
    );
  }
}

/// Setting row that opens something: icon, title, hint and a chevron.
class ColituActionRow extends StatelessWidget {
  const ColituActionRow({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.onTap,
    this.trailing,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return ColituTile(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      child: Row(
        children: [
          ColituRoundIcon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ColituText.label),
                if (hint != null && hint!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    hint!,
                    style: ColituText.small,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (badge != null) ...[badge!, const SizedBox(width: 8)],
          trailing ??
              const Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: ColituColors.dim,
              ),
        ],
      ),
    );
  }
}

/// Text field with label and inline error.
class ColituField extends StatelessWidget {
  const ColituField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.error,
    this.suffix,
    this.prefixIcon,
    this.onSubmitted,
    this.autocorrect = true,
    this.enabled = true,
    this.maxLength,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final String? error;
  final Widget? suffix;
  final IconData? prefixIcon;
  final ValueChanged<String>? onSubmitted;
  final bool autocorrect;
  final bool enabled;

  /// Longest accepted input; by default 256 for passwords and 254 (the
  /// longest valid address) for e-mail fields.
  final int? maxLength;

  int? get _limit =>
      maxLength ??
      (obscureText
          ? 256
          : keyboardType == TextInputType.emailAddress
          ? 254
          : null);

  @override
  Widget build(BuildContext context) {
    final hasError = error != null && error!.isNotEmpty;
    final limit = _limit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: ColituText.small.copyWith(
              color: ColituColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        TextField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          autofillHints: autofillHints,
          autocorrect: autocorrect,
          enableSuggestions: autocorrect,
          enabled: enabled,
          onSubmitted: onSubmitted,
          inputFormatters: limit == null
              ? null
              : [LengthLimitingTextInputFormatter(limit)],
          cursorColor: ColituColors.lilac,
          style: ColituText.body.copyWith(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: ColituText.body.copyWith(
              color: ColituColors.dim,
              fontSize: 16,
            ),
            filled: true,
            fillColor: ColituColors.field,
            prefixIcon: prefixIcon == null
                ? null
                : Icon(prefixIcon, size: 20, color: ColituColors.dim),
            suffixIcon: suffix,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 15,
            ),
            border: _border(hasError ? ColituColors.danger : ColituColors.line),
            enabledBorder: _border(
              hasError ? ColituColors.danger : ColituColors.line,
            ),
            disabledBorder: _border(ColituColors.line),
            focusedBorder: _border(
              hasError ? ColituColors.danger : ColituColors.violet,
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 6),
            child: Text(
              error!,
              style: ColituText.small.copyWith(color: ColituColors.danger),
            ),
          ),
      ],
    );
  }

  OutlineInputBorder _border(Color color) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(ColituRadius.md),
      borderSide: BorderSide(color: color),
    );
  }
}

class ColituCheck extends StatelessWidget {
  const ColituCheck({
    super.key,
    required this.value,
    required this.onChanged,
    required this.child,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              gradient: value ? ColituGradients.accent : null,
              color: value ? null : ColituColors.field,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: value ? Colors.transparent : ColituColors.lineStrong,
              ),
            ),
            child: value
                ? const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: ColituColors.onAccent,
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ── Brand ──────────────────────────────────────────────────────────────────

/// "COLITU" wordmark, optionally followed by "VPN", traced from the brand
/// banner. Height sets the glyph height; width follows.
class ColituWordmark extends StatelessWidget {
  const ColituWordmark({
    super.key,
    this.height = 18,
    this.withVpn = true,
    this.color = ColituColors.text,
    this.vpnGradient = true,
  });

  final double height;
  final bool withVpn;
  final Color color;
  final bool vpnGradient;

  static const _gap =
      46.0; // banner spacing between COLITU and VPN, in glyph units

  @override
  Widget build(BuildContext context) {
    final scale = height / 100;
    final width =
        (colituWordmarkWidth + (withVpn ? _gap + vpnWordmarkWidth : 0)) * scale;
    return Semantics(
      label: withVpn ? 'Colitu VPN' : 'Colitu',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: CustomPaint(
          size: Size(width, height),
          painter: _WordmarkPainter(
            color: color,
            withVpn: withVpn,
            vpnGradient: vpnGradient,
          ),
        ),
      ),
    );
  }
}

class _WordmarkPainter extends CustomPainter {
  _WordmarkPainter({
    required this.color,
    required this.withVpn,
    required this.vpnGradient,
  });

  final Color color;
  final bool withVpn;
  final bool vpnGradient;

  static final _colitu = buildWordmarkPath(colituGlyphs);
  static final _vpn = buildWordmarkPath(vpnGlyphs);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / 100;
    canvas.save();
    canvas.scale(scale);
    canvas.drawPath(_colitu, Paint()..color = color);
    if (withVpn) {
      canvas.translate(colituWordmarkWidth + ColituWordmark._gap, 0);
      final paint = Paint();
      if (vpnGradient) {
        paint.shader = ColituGradients.accent.createShader(
          const Rect.fromLTWH(0, 0, vpnWordmarkWidth, 100),
        );
      } else {
        paint.color = color;
      }
      canvas.drawPath(_vpn, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordmarkPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.withVpn != withVpn ||
      oldDelegate.vpnGradient != vpnGradient;
}

class ColituMark extends StatelessWidget {
  const ColituMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.asset(
        'assets/brand/mark.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(gradient: ColituGradients.accent),
        ),
      ),
    );
  }
}

// ── Navigation ─────────────────────────────────────────────────────────────

class ColituNavItem {
  const ColituNavItem({required this.icon, required this.label, this.badge = 0});

  final IconData icon;
  final String label;

  /// Unread count drawn on the button (live support); 0 hides it.
  final int badge;
}

/// Floating pill with one round button per tab; the active one is lavender.
class ColituNavBar extends StatelessWidget {
  const ColituNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<ColituNavItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 0, 0, math.max(bottom, 14)),
      // A Row (not Center) so the bar keeps its own height inside the
      // Scaffold's loose bottom slot.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xF2141419),
              borderRadius: BorderRadius.circular(ColituRadius.pill),
              border: Border.all(color: ColituColors.lineStrong),
              boxShadow: const [
                BoxShadow(
                  color: Color(0xB3000000),
                  blurRadius: 30,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Semantics(
                    button: true,
                    selected: i == index,
                    label: items[i].label,
                    child: ColituPressable(
                      onTap: () => onChanged(i),
                      scale: 0.9,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOutCubic,
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          gradient: i == index ? ColituGradients.accent : null,
                          color: i == index ? null : ColituColors.surface2,
                          shape: BoxShape.circle,
                          boxShadow: i == index
                              ? const [
                                  BoxShadow(
                                    color: Color(0x669F8CFF),
                                    blurRadius: 18,
                                    offset: Offset(0, 6),
                                  ),
                                ]
                              : null,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            Icon(
                              items[i].icon,
                              size: 22,
                              color: i == index
                                  ? ColituColors.onAccent
                                  : ColituColors.muted,
                            ),
                            if (items[i].badge > 0)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: ColituColors.danger,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFF0E0E14), width: 2),
                                  ),
                                  child: Text(
                                    items[i].badge > 9 ? '9+' : '${items[i].badge}',
                                    style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w700, color: Colors.white, height: 1),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Toast ──────────────────────────────────────────────────────────────────

void showColituToast(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  if (message.trim().isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 100),
      duration: Duration(seconds: error ? 5 : 3),
      backgroundColor: error
          ? const Color(0xF2331419)
          : const Color(0xF21B1B24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ColituRadius.md),
        side: BorderSide(
          color: error ? const Color(0x66FF6B7A) : ColituColors.lineStrong,
        ),
      ),
      content: Row(
        children: [
          Icon(
            error
                ? CupertinoIcons.exclamationmark_circle
                : CupertinoIcons.checkmark_circle,
            size: 18,
            color: error ? const Color(0xFFFFA3AE) : ColituColors.success,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: ColituText.body)),
        ],
      ),
    ),
  );
}

/// Inline notice inside a page (errors, offline hints).
class ColituNotice extends StatelessWidget {
  const ColituNotice(this.message, {super.key, this.error = true, this.action});

  final String message;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = error ? ColituColors.danger : ColituColors.lilac;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(ColituRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error
                ? CupertinoIcons.exclamationmark_triangle
                : CupertinoIcons.info_circle,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: ColituText.body.copyWith(fontSize: 14)),
                if (action != null) ...[const SizedBox(height: 8), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Page header: kicker + title + optional subtitle.
class ColituPageHeader extends StatelessWidget {
  const ColituPageHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String kicker;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ColituKicker(kicker),
              const SizedBox(height: 8),
              Text(title, style: ColituText.h1),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(subtitle!, style: ColituText.muted),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

/// Fades and lifts its child in once, with an optional delay; used to stagger
/// cards when a page opens.
class ColituReveal extends StatefulWidget {
  const ColituReveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 520),
    this.offset = 18,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double offset;

  @override
  State<ColituReveal> createState() => _ColituRevealState();
}

class _ColituRevealState extends State<ColituReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - _curve.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
