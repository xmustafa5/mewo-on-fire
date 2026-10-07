import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ember.dart';
import 'motion.dart';

/// The flame: the app's mark, and the sign that Claude is working. Flickers
/// gently unless the system asks for less motion.
class FlameMark extends StatefulWidget {
  const FlameMark({super.key, this.size = 64, this.animate = true, this.glow = true});

  final double size;
  final bool animate;
  final bool glow;

  @override
  State<FlameMark> createState() => _FlameMarkState();
}

class _FlameMarkState extends State<FlameMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(FlameMark old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.animate && !reducedMotion(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
      _c.value = 0.3;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size(widget.size, widget.size * 1.2),
          painter: _FlamePainter(_c.value, glow: widget.glow),
        ),
      ),
    );
  }
}

class _FlamePainter extends CustomPainter {
  const _FlamePainter(this.t, {required this.glow});

  final double t;
  final bool glow;

  Path _tongue(Size s, {required double scale, required double sway, required double lift}) {
    final w = s.width;
    final base = s.height - lift;
    final hh = s.height * scale;
    final hw = w * scale / 2;
    final cx = w / 2;
    final tipX = cx + sway * w;
    final p = Path()..moveTo(cx, base);
    p.cubicTo(cx - hw * 1.18, base, cx - hw * 1.08, base - hh * 0.46, cx - hw * 0.56, base - hh * 0.6);
    p.cubicTo(cx - hw * 0.3, base - hh * 0.7, tipX - hw * 0.22, base - hh * 0.82, tipX, base - hh);
    p.cubicTo(tipX + hw * 0.24, base - hh * 0.8, cx + hw * 0.56, base - hh * 0.68, cx + hw * 0.62, base - hh * 0.56);
    p.cubicTo(cx + hw * 1.12, base - hh * 0.42, cx + hw * 1.18, base, cx, base);
    p.close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final sway = math.sin(a) * 0.055 + math.sin(a * 2.3 + 1.1) * 0.02;
    final rise = 0.96 + 0.04 * math.sin(a * 1.7 + 0.6);
    final rect = Offset.zero & size;

    final outer = _tongue(size, scale: rise, sway: sway, lift: 0);
    if (glow) {
      canvas.drawPath(
        outer,
        Paint()
          ..color = Ember.flame.withValues(alpha: 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.14),
      );
    }
    canvas.drawPath(
      outer,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Ember.heat, Ember.flame, Ember.amber],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    final inner = _tongue(
      size,
      scale: 0.56 * rise,
      sway: -sway * 0.6 + math.sin(a * 3.1) * 0.015,
      lift: size.height * 0.03,
    );
    canvas.drawPath(
      inner,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Ember.amber, Ember.gold, Color(0xFFFFF4D6)],
          stops: [0, 0.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_FlamePainter old) => old.t != t || old.glow != glow;
}

/// A flame icon the size of text, for chips and labels.
class FlameIcon extends StatelessWidget {
  const FlameIcon({super.key, this.size = 14, this.animate = true});

  final double size;
  final bool animate;

  @override
  Widget build(BuildContext context) =>
      FlameMark(size: size * 0.85, animate: animate, glow: false);
}

/// The warm, slowly drifting glow behind every screen.
class EmberBackground extends StatefulWidget {
  const EmberBackground({super.key, this.child, this.animate = true});

  final Widget? child;
  final bool animate;

  @override
  State<EmberBackground> createState() => _EmberBackgroundState();
}

class _EmberBackgroundState extends State<EmberBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 18));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(EmberBackground old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.animate && !reducedMotion(context);
    if (run && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!run && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Ember.bg),
        RepaintBoundary(
          child: IgnorePointer(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_c.value);
                  final h = MediaQuery.sizeOf(context).height;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: -170 + 50 * t,
                        right: -150 - 30 * t,
                        child: const _Blob(color: Ember.flame, size: 460, alpha: 0.22),
                      ),
                      Positioned(
                        bottom: -220 + 40 * t,
                        left: -190 + 50 * t,
                        child: const _Blob(color: Ember.mewo, size: 520, alpha: 0.16),
                      ),
                      Positioned(
                        top: h * 0.42 - 60 * t,
                        right: -240,
                        child: const _Blob(color: Ember.ember, size: 420, alpha: 0.11),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        ?widget.child,
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size, required this.alpha});

  final Color color;
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
            stops: const [0, 1],
          ),
        ),
      ),
    );
  }
}
