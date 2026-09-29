import 'dart:math' as math;

import 'package:flutter/material.dart';

enum Fx6dKind { cross, heart }

/// Boutons croix / cœur — animation 6d « Trou noir » (port de
/// `Croix et cœur personnalisés/export/croix-coeur-6d.js`).
///
/// Au tap : l'icône est aspirée (échelle 0 en tournant de 540°), disparaît,
/// puis ressort en rebond (1.3 → 1, 720°) ; le bouton respire (.9 → 1.1 → 1) ;
/// à 470 ms une onde et 10 particules partent du centre.
class Fx6dButton extends StatefulWidget {
  const Fx6dButton({
    super.key,
    required this.kind,
    required this.onTap,
    this.size = 76,
    this.semanticLabel,
  });

  final Fx6dKind kind;
  final VoidCallback onTap;
  final double size;
  final String? semanticLabel;

  @override
  State<Fx6dButton> createState() => _Fx6dButtonState();
}

class _Fx6dButtonState extends State<Fx6dButton>
    with SingleTickerProviderStateMixin {
  // 470 ms avant l'onde + 600 ms de particules.
  static const _totalMs = 1070.0;
  static const _mainMs = 800.0;
  static const _fxStartMs = 470.0;

  static const _ease = Cubic(.4, 0, .2, 1);
  static const _burstEase = Cubic(.2, .8, .3, 1);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1070),
  );
  List<_Particle> _particles = const [];

  Color get _color => widget.kind == Fx6dKind.heart
      ? const Color(0xFFFF6B8A)
      : const Color(0xFFFFFFFF);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _play() {
    final rnd = math.Random();
    _particles = [
      for (var i = 0; i < 10; i++)
        _Particle(
          angle: (i / 10) * math.pi * 2 + rnd.nextDouble() * .3,
          size: 4 + rnd.nextDouble() * 4,
          dist: 50 * (.8 + rnd.nextDouble() * .4),
        ),
    ];
    _c.forward(from: 0);
    widget.onTap();
  }

  /// Interpole linéairement entre [stops] (offset → valeur), avec l'easing
  /// [_ease] appliqué segment par segment, comme les keyframes WAAPI.
  static double _keys(double t, List<(double, double)> stops) {
    if (t <= stops.first.$1) return stops.first.$2;
    for (var i = 1; i < stops.length; i++) {
      final (o1, v1) = stops[i];
      if (t <= o1) {
        final (o0, v0) = stops[i - 1];
        final k = _ease.transform((t - o0) / (o1 - o0));
        return v0 + (v1 - v0) * k;
      }
    }
    return stops.last.$2;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _play,
        child: SizedBox(
          width: s,
          height: s,
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) {
              final ms = _c.value * _totalMs;
              final running = _c.isAnimating;
              final t = running ? (ms / _mainMs).clamp(0.0, 1.0) : 1.0;
              final btnScale = _keys(t, const [
                (0, 1),
                (.45, .9),
                (.75, 1.1),
                (1, 1),
              ]);
              final iconScale = _keys(t, const [
                (0, 1),
                (.45, 0),
                (.55, 0),
                (.82, 1.3),
                (1, 1),
              ]);
              final iconOpacity = _keys(t, const [
                (0, 1),
                (.45, .3),
                (.55, 0),
                (.82, 1),
                (1, 1),
              ]);
              final iconRot = _keys(t, const [
                (0, 0),
                (.45, 540),
                (.55, 540),
                (.82, 720),
                (1, 720),
              ]);
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: btnScale,
                    child: Container(
                      width: s,
                      height: s,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .08),
                        ),
                        gradient: const RadialGradient(
                          center: Alignment(0, -.3),
                          radius: .82,
                          colors: [
                            Color(0xFF3A3A3E),
                            Color(0xFF26262A),
                            Color(0xFF26262A),
                          ],
                          stops: [0, .7, 1],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .5),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Opacity(
                        opacity: iconOpacity.clamp(0.0, 1.0),
                        child: Transform.rotate(
                          angle: iconRot * math.pi / 180,
                          child: Transform.scale(
                            scale: iconScale,
                            child: CustomPaint(
                              size: Size.square(
                                widget.kind == Fx6dKind.heart ? 32 : 28,
                              ),
                              painter: _IconPainter(widget.kind),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (running && ms >= _fxStartMs)
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size.square(s),
                        painter: _BurstPainter(
                          elapsedMs: ms - _fxStartMs,
                          color: _color,
                          particles: _particles,
                          radius: s / 2,
                          burstEase: _burstEase,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Particle {
  const _Particle({
    required this.angle,
    required this.size,
    required this.dist,
  });

  final double angle;
  final double size;
  final double dist;
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.kind);

  final Fx6dKind kind;

  // Cœur du SVG d'origine (viewBox 24×24).
  static Path _heart() => Path()
    ..moveTo(12, 20.5)
    ..cubicTo(11.7, 20.5, 11.4, 20.4, 11.2, 20.2)
    ..cubicTo(6.4, 16.3, 3, 13.3, 3, 9.4)
    ..cubicTo(3, 6.9, 4.9, 5, 7.3, 5)
    ..cubicTo(9.2, 5, 10.6, 6, 12, 7.7)
    ..cubicTo(13.4, 6, 14.8, 5, 16.7, 5)
    ..cubicTo(19.1, 5, 21, 6.9, 21, 9.4)
    ..cubicTo(21, 13.3, 17.6, 16.3, 12.8, 20.2)
    ..cubicTo(12.6, 20.4, 12.3, 20.5, 12, 20.5)
    ..close();

  static Path _cross() => Path()
    ..moveTo(6, 6)
    ..lineTo(18, 18)
    ..moveTo(18, 6)
    ..lineTo(6, 18);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    if (kind == Fx6dKind.heart) {
      final path = _heart();
      const c = Color(0xFFFF6B8A);
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFFF6B8A).withValues(alpha: .8)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawPath(path, Paint()..color = c);
    } else {
      final path = _cross();
      Paint stroke() => Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(
        path,
        stroke()
          ..color = Colors.white.withValues(alpha: .55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawPath(path, stroke()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.kind != kind;
}

class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.elapsedMs,
    required this.color,
    required this.particles,
    required this.radius,
    required this.burstEase,
  });

  final double elapsedMs;
  final Color color;
  final List<_Particle> particles;
  final double radius;
  final Curve burstEase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    // Onde : anneau 1 px, échelle 1 → 1.7, opacité .45 → 0 en 550 ms.
    final rp = (elapsedMs / 550).clamp(0.0, 1.0);
    if (rp < 1) {
      final k = burstEase.transform(rp);
      canvas.drawCircle(
        center,
        (radius + 1) * (1 + .7 * k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: .45 * (1 - k)),
      );
    }

    // Particules : 600 ms, s'éloignent en rétrécissant (1 → .2) et s'éteignent.
    final pp = (elapsedMs / 600).clamp(0.0, 1.0);
    if (pp < 1) {
      final k = burstEase.transform(pp);
      for (final p in particles) {
        final pos = center + Offset(math.cos(p.angle), math.sin(p.angle)) * (p.dist * k);
        final r = p.size / 2 * (1 - .8 * k);
        final a = 1 - k;
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..color = color.withValues(alpha: .8 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawCircle(pos, r, Paint()..color = color.withValues(alpha: a));
      }
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.elapsedMs != elapsedMs;
}
