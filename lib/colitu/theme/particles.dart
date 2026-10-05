import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// Shapes the particle field can take.
enum ColituParticleMode {
  /// A wavy ring of dots that ripples in 3D; sits behind the power button.
  ring,

  /// A slowly turning globe of dots; hero of the onboarding and sign-in.
  sphere,

  /// A rotating wireframe gem with sparks; hero of the plan page.
  gem,
}

/// Live 3D particle field drawn on a canvas: no assets, no shaders, just a
/// few hundred projected points redrawn every frame. [energy] (0..1) drives
/// speed and brightness so the same field can idle, work and celebrate.
class ColituParticles extends StatefulWidget {
  const ColituParticles({
    super.key,
    this.mode = ColituParticleMode.ring,
    this.size = 280,
    this.energy = 0.35,
    this.color = ColituColors.violet,
    this.color2 = ColituColors.lilac,
    this.animate = true,
  });

  final ColituParticleMode mode;
  final double size;
  final double energy;
  final Color color;
  final Color color2;
  final bool animate;

  @override
  State<ColituParticles> createState() => _ColituParticlesState();
}

class _ColituParticlesState extends State<ColituParticles>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final _ParticleSet _set = _ParticleSet(widget.mode, widget.size);
  double _time = 0;
  double _energy = 0;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _energy = widget.energy;
    _ticker = createTicker(_onTick);
    if (widget.animate) _ticker.start();
  }

  @override
  void didUpdateWidget(covariant ColituParticles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_ticker.isActive) _ticker.start();
    if (!widget.animate && _ticker.isActive) _ticker.stop();
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    // Energy eases toward the target so state changes ramp instead of snap.
    _energy += (widget.energy - _energy) * math.min(1, dt * 3.2);
    _time += dt * (0.55 + _energy * 1.35);
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _ParticlePainter(
          set: _set,
          time: _time,
          energy: widget.animate ? _energy : widget.energy,
          color: widget.color,
          color2: widget.color2,
        ),
      ),
    );
  }
}

class _Particle {
  _Particle(this.a, this.r, this.phase, this.size, this.x, this.y, this.z);

  final double a; // angle for ring points
  final double r; // radius factor for ring points
  final double phase;
  final double size;
  final double x, y, z; // unit-sphere position for sphere points
}

class _ParticleSet {
  _ParticleSet(this.mode, double size) {
    final random = math.Random(7);
    switch (mode) {
      case ColituParticleMode.ring:
        final n = size < 220 ? 700 : 1250;
        for (var i = 0; i < n; i++) {
          final a = random.nextDouble() * math.pi * 2;
          final r = 0.6 + 0.4 * math.sqrt(random.nextDouble());
          particles.add(
            _Particle(a, r, random.nextDouble() * 6.283, 0.9 + random.nextDouble() * 1.5, 0, 0, 0),
          );
        }
      case ColituParticleMode.sphere:
        final n = size < 220 ? 520 : 900;
        final golden = math.pi * (3 - math.sqrt(5));
        for (var i = 0; i < n; i++) {
          final y = 1 - (i / (n - 1)) * 2;
          final radius = math.sqrt(1 - y * y);
          final theta = golden * i;
          particles.add(
            _Particle(
              0,
              0,
              random.nextDouble() * 6.283,
              0.8 + random.nextDouble() * 1.3,
              math.cos(theta) * radius,
              y,
              math.sin(theta) * radius,
            ),
          );
        }
      case ColituParticleMode.gem:
        for (var i = 0; i < 70; i++) {
          final a = random.nextDouble() * math.pi * 2;
          final r = 0.75 + 0.55 * random.nextDouble();
          particles.add(
            _Particle(a, r, random.nextDouble() * 6.283, 0.8 + random.nextDouble() * 1.6, 0, 0, 0),
          );
        }
    }
  }

  final ColituParticleMode mode;
  final particles = <_Particle>[];
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({
    required this.set,
    required this.time,
    required this.energy,
    required this.color,
    required this.color2,
  });

  final _ParticleSet set;
  final double time;
  final double energy;
  final Color color;
  final Color color2;

  static const _focal = 2.7;

  @override
  void paint(Canvas canvas, Size size) {
    switch (set.mode) {
      case ColituParticleMode.ring:
        _paintRing(canvas, size);
      case ColituParticleMode.sphere:
        _paintSphere(canvas, size);
      case ColituParticleMode.gem:
        _paintGem(canvas, size);
    }
  }

  void _glow(Canvas canvas, Offset center, double radius, double alpha) {
    if (alpha <= 0.01) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.35),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  /// Draws projected points in a few alpha/size buckets with drawPoints, which
  /// is far cheaper than one drawCircle per particle.
  void _drawBuckets(Canvas canvas, List<List<Offset>> buckets, List<double> widths, List<double> alphas, {bool mix = false}) {
    for (var i = 0; i < buckets.length; i++) {
      if (buckets[i].isEmpty) continue;
      final tint = mix ? Color.lerp(color, color2, i / math.max(1, buckets.length - 1))! : color2;
      canvas.drawPoints(
        ui.PointMode.points,
        buckets[i],
        Paint()
          ..color = tint.withValues(alpha: alphas[i])
          ..strokeWidth = widths[i]
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _paintRing(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    _glow(canvas, center, radius * 0.95, 0.10 + 0.30 * energy);

    const tilt = 0.82; // radians: view the ring from above at an angle
    final cosT = math.cos(tilt);
    final sinT = math.sin(tilt);
    final spin = time * 0.22;
    final amp = 0.16 + 0.26 * energy;
    // 3 depth × 3 size buckets.
    final buckets = List.generate(9, (_) => <Offset>[]);
    for (final p in set.particles) {
      final a = p.a + spin;
      final wave = math.sin(p.a * 3 + time * 1.5 + p.phase) * 0.5 +
          math.sin(p.a * 6 - time * 0.9) * 0.28 +
          math.sin(p.r * 9 + time * 1.15 + p.phase) * 0.22;
      final r = p.r * (1 + 0.09 * wave * (0.5 + energy));
      final x = r * math.cos(a);
      final y = r * math.sin(a);
      final z = amp * wave;
      final y2 = y * cosT - z * sinT;
      final z2 = y * sinT + z * cosT;
      final scale = _focal / (_focal + z2);
      final px = center.dx + x * scale * radius * 0.92;
      final py = center.dy + y2 * scale * radius * 0.92;
      final depth = ((z2 + 0.6) / 1.2).clamp(0.0, 1.0);
      final depthBucket = depth < 0.4 ? 0 : (depth < 0.7 ? 1 : 2);
      final sizeBucket = p.size < 1.4 ? 0 : (p.size < 1.9 ? 1 : 2);
      buckets[depthBucket * 3 + sizeBucket].add(Offset(px, py));
    }
    final base = 0.34 + 0.5 * energy;
    _drawBuckets(
      canvas,
      buckets,
      const [1.6, 2.2, 2.9, 1.7, 2.4, 3.1, 1.9, 2.6, 3.4],
      [
        base * 0.28, base * 0.3, base * 0.34,
        base * 0.55, base * 0.6, base * 0.66,
        base * 0.95, base * 1.0, base * 1.0,
      ].map((v) => v.clamp(0.0, 1.0)).toList(),
      mix: true,
    );
  }

  void _paintSphere(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 * 0.78;
    _glow(canvas, center, size.width / 2, 0.12 + 0.2 * energy);

    final ry = time * 0.32;
    const rx = 0.42;
    final cy = math.cos(ry), sy = math.sin(ry);
    final cx = math.cos(rx), sx = math.sin(rx);
    final buckets = List.generate(6, (_) => <Offset>[]);
    // Faint equator and meridian for structure.
    final ringPaint = Paint()
      ..color = color.withValues(alpha: 0.18 + 0.12 * energy)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final ring in [0, 1]) {
      final path = Path();
      for (var i = 0; i <= 96; i++) {
        final t = i / 96 * math.pi * 2;
        double x, y, z;
        if (ring == 0) {
          x = math.cos(t);
          y = 0;
          z = math.sin(t);
        } else {
          x = math.cos(t);
          y = math.sin(t);
          z = 0;
        }
        final p = _project(x, y, z, cy, sy, cx, sx, center, radius);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, ringPaint);
    }
    for (final p in set.particles) {
      final breathe = 1 + 0.025 * math.sin(time * 1.3 + p.phase) * (0.4 + energy);
      final x1 = p.x * cy + p.z * sy;
      final z1 = -p.x * sy + p.z * cy;
      final y2 = p.y * cx - z1 * sx;
      final z2 = p.y * sx + z1 * cx;
      final scale = _focal / (_focal + z2 * 0.9);
      final px = center.dx + x1 * scale * radius * breathe;
      final py = center.dy + y2 * scale * radius * breathe;
      final depth = ((z2 + 1) / 2).clamp(0.0, 1.0);
      final depthBucket = depth < 0.35 ? 0 : (depth < 0.62 ? 1 : 2);
      final sizeBucket = p.size < 1.45 ? 0 : 1;
      buckets[depthBucket * 2 + sizeBucket].add(Offset(px, py));
    }
    final base = 0.3 + 0.5 * energy;
    _drawBuckets(
      canvas,
      buckets,
      const [1.3, 1.9, 1.6, 2.3, 2.0, 2.9],
      [base * 0.18, base * 0.22, base * 0.5, base * 0.58, base * 0.95, base * 1.0]
          .map((v) => v.clamp(0.0, 1.0))
          .toList(),
      mix: true,
    );
  }

  Offset _project(double x, double y, double z, double cy, double sy, double cx, double sx, Offset center, double radius) {
    final x1 = x * cy + z * sy;
    final z1 = -x * sy + z * cy;
    final y2 = y * cx - z1 * sx;
    final z2 = y * sx + z1 * cx;
    final scale = _focal / (_focal + z2 * 0.9);
    return Offset(center.dx + x1 * scale * radius, center.dy + y2 * scale * radius);
  }

  static final _gemVertices = () {
    const phi = 1.618033988749895;
    final raw = <List<double>>[
      [-1, phi, 0], [1, phi, 0], [-1, -phi, 0], [1, -phi, 0],
      [0, -1, phi], [0, 1, phi], [0, -1, -phi], [0, 1, -phi],
      [phi, 0, -1], [phi, 0, 1], [-phi, 0, -1], [-phi, 0, 1],
    ];
    final norm = math.sqrt(1 + phi * phi);
    return [for (final v in raw) [v[0] / norm, v[1] / norm, v[2] / norm]];
  }();

  static const _gemEdges = <List<int>>[
    [0, 1], [0, 5], [0, 7], [0, 10], [0, 11],
    [1, 5], [1, 7], [1, 8], [1, 9],
    [2, 3], [2, 4], [2, 6], [2, 10], [2, 11],
    [3, 4], [3, 6], [3, 8], [3, 9],
    [4, 5], [4, 9], [4, 11],
    [5, 9], [5, 11],
    [6, 7], [6, 8], [6, 10],
    [7, 8], [7, 10],
    [8, 9], [10, 11],
  ];

  void _paintGem(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 * 0.62;
    _glow(canvas, center, size.width / 2, 0.16 + 0.22 * energy);

    final ry = time * 0.5;
    final rx = 0.38 + 0.18 * math.sin(time * 0.7);
    final cy = math.cos(ry), sy = math.sin(ry);
    final cx = math.cos(rx), sx = math.sin(rx);
    final float = math.sin(time * 1.1) * size.height * 0.018;
    final origin = center.translate(0, float);

    final projected = <Offset>[];
    final depths = <double>[];
    for (final v in _gemVertices) {
      final x1 = v[0] * cy + v[2] * sy;
      final z1 = -v[0] * sy + v[2] * cy;
      final y2 = v[1] * cx - z1 * sx;
      final z2 = v[1] * sx + z1 * cx;
      final scale = _focal / (_focal + z2 * 0.8);
      projected.add(Offset(origin.dx + x1 * scale * radius, origin.dy + y2 * scale * radius));
      depths.add(((z2 + 1) / 2).clamp(0.0, 1.0));
    }
    // Faces are not filled; the body is a translucent core so the wireframe
    // reads as glass.
    canvas.drawCircle(
      origin,
      radius * 0.72,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.05)],
        ).createShader(Rect.fromCircle(center: origin, radius: radius * 0.72)),
    );
    final edges = [..._gemEdges]
      ..sort((a, b) => (depths[a[0]] + depths[a[1]]).compareTo(depths[b[0]] + depths[b[1]]));
    for (final e in edges) {
      final d = (depths[e[0]] + depths[e[1]]) / 2;
      canvas.drawLine(
        projected[e[0]],
        projected[e[1]],
        Paint()
          ..color = Color.lerp(color, color2, d)!.withValues(alpha: 0.25 + 0.7 * d)
          ..strokeWidth = 1.1 + 1.1 * d
          ..strokeCap = StrokeCap.round,
      );
    }
    for (var i = 0; i < projected.length; i++) {
      final d = depths[i];
      canvas.drawCircle(
        projected[i],
        1.6 + 2.2 * d,
        Paint()..color = color2.withValues(alpha: 0.5 + 0.5 * d),
      );
      if (d > 0.75) {
        canvas.drawCircle(
          projected[i],
          7 + 6 * d,
          Paint()..color = color2.withValues(alpha: 0.12 * (d - 0.75) / 0.25),
        );
      }
    }
    // Sparks orbiting the gem.
    final sparks = <Offset>[];
    for (final p in set.particles) {
      final a = p.a + time * (0.35 + 0.3 * p.r);
      final x = math.cos(a) * p.r;
      final z = math.sin(a) * p.r;
      final y = math.sin(a * 2 + p.phase) * 0.35;
      final x1 = x * cy + z * sy;
      final z1 = -x * sy + z * cy;
      final y2 = y * cx - z1 * sx;
      final z2 = y * sx + z1 * cx;
      final scale = _focal / (_focal + z2 * 0.8);
      sparks.add(Offset(origin.dx + x1 * scale * radius, origin.dy + y2 * scale * radius));
    }
    canvas.drawPoints(
      ui.PointMode.points,
      sparks,
      Paint()
        ..color = color2.withValues(alpha: 0.35 + 0.35 * energy)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) =>
      oldDelegate.time != time ||
      oldDelegate.energy != energy ||
      oldDelegate.set != set ||
      oldDelegate.color != color ||
      oldDelegate.color2 != color2;
}

/// Connection state of the power control.
enum ColituPowerState { off, busy, on }

/// The big round connect button with the particle ring behind it. The ring
/// idles when off, churns while connecting and glows steadily when on. The
/// centre shows the power glyph, or [child] (the session clock) when set.
class ColituPowerButton extends StatelessWidget {
  const ColituPowerButton({
    super.key,
    required this.state,
    this.onTap,
    this.size = 300,
    this.child,
    this.semanticsLabel,
  });

  final ColituPowerState state;
  final VoidCallback? onTap;
  final double size;
  final Widget? child;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final energy = switch (state) {
      ColituPowerState.off => 0.22,
      ColituPowerState.busy => 1.0,
      ColituPowerState.on => 0.62,
    };
    final button = size * 0.46;
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ColituParticles(
              mode: ColituParticleMode.ring,
              size: size,
              energy: energy,
              color: state == ColituPowerState.on ? ColituColors.violet : ColituColors.blue2,
              color2: state == ColituPowerState.on ? ColituColors.pink : ColituColors.lilac,
            ),
            ColituPressable(
              onTap: onTap,
              scale: 0.94,
              child: _PowerCore(state: state, size: button, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class _PowerCore extends StatefulWidget {
  const _PowerCore({required this.state, required this.size, this.child});

  final ColituPowerState state;
  final double size;
  final Widget? child;

  @override
  State<_PowerCore> createState() => _PowerCoreState();
}

class _PowerCoreState extends State<_PowerCore>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.state == ColituPowerState.on;
    final busy = widget.state == ColituPowerState.busy;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_pulse.value);
        final glow = on ? 0.55 + 0.25 * t : busy ? 0.35 + 0.45 * t : 0.28;
        final spread = busy ? 4 + 6 * t : on ? 4 + 3 * t : 0.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFD0C4FF), Color(0xFF9F8CFF), Color(0xFF7A69EE)],
            ),
            boxShadow: [
              BoxShadow(
                color: ColituColors.violet.withValues(alpha: glow),
                blurRadius: 42,
                spreadRadius: spread,
              ),
              const BoxShadow(
                color: Color(0x80000000),
                blurRadius: 30,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: child,
        );
      },
      child: Container(
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1.2),
          gradient: RadialGradient(
            center: const Alignment(-0.3, -0.4),
            colors: [Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0)],
          ),
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: widget.child ??
                Icon(
                  busy ? CupertinoIcons.shield_lefthalf_fill : CupertinoIcons.power,
                  key: ValueKey(widget.state),
                  size: widget.size * 0.30,
                  color: Colors.white,
                ),
          ),
        ),
      ),
    );
  }
}
