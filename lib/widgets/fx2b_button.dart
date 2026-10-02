import 'dart:math' as math;

import 'package:flutter/material.dart';

enum Fx2bKind { cross, heart }

/// Boutons croix / cœur — style 2b + animation 4b « Éclosion » (port de
/// `Croix et cœur personnalisé(s)/export/croix-coeur-2b.js`).
///
/// ✕ : disque clair, croix sombre. ❤ : disque en dégradé rose, cœur blanc.
/// Au tap : la croix rétrécit en tournant de 180° puis ressort en rebond
/// (1.3 → 1) ; le cœur pulse (.5 → 1.4 → .95 → 1). Le bouton respire à
/// ~200 ms, une onde fine part du centre, et — pour le cœur seulement —
/// 10 particules.
class Fx2bButton extends StatefulWidget {
  const Fx2bButton({
    super.key,
    required this.kind,
    required this.onTap,
    this.size = 76,
    this.semanticLabel,
  });

  final Fx2bKind kind;
  final VoidCallback onTap;

  /// Diamètre du bouton ; icônes et particules suivent (référence : 76).
  final double size;
  final String? semanticLabel;

  @override
  State<Fx2bButton> createState() => _Fx2bButtonState();
}

class _Fx2bButtonState extends State<Fx2bButton>
    with SingleTickerProviderStateMixin {
  static const _totalMs = 800.0;
  static const _ease = Cubic(.4, 0, .2, 1);
  static const _burstEase = Cubic(.2, .8, .3, 1);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  List<_Particle> _particles = const [];

  bool get _heart => widget.kind == Fx2bKind.heart;

  /// Quand le bouton respire et que l'onde part (ms).
  double get _fxStart => _heart ? 190 : 200;
  double get _iconMs => _heart ? 620 : 560;
  double get _bumpMs => _heart ? 380 : 360;
  double get _bumpAmt => _heart ? .12 : .10;

  Color get _rippleColor => _heart
      ? const Color(0xFFFF6B8A)
      : const Color(0xFFFFFFFF).withValues(alpha: .9);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _play() {
    final rnd = math.Random();
    _particles = _heart
        ? [
            for (var i = 0; i < 10; i++)
              _Particle(
                angle: (i / 10) * math.pi * 2 + rnd.nextDouble() * .3,
                size: 4 + rnd.nextDouble() * 4,
                dist: 56 * widget.size / 76 * (.8 + rnd.nextDouble() * .4),
              ),
          ]
        : const [];
    _c.forward(from: 0);
    widget.onTap();
  }

  /// Interpole entre [stops] (offset → valeur), avec [_ease] sur chaque
  /// segment, comme les keyframes WAAPI du script d'origine.
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
              final running = _c.isAnimating;
              final ms = _c.value * _totalMs;

              // L'icône.
              final ti = running ? (ms / _iconMs).clamp(0.0, 1.0) : 1.0;
              final iconScale = _heart
                  ? _keys(ti, const [(0, 1), (.3, .5), (.6, 1.4), (.8, .95), (1, 1)])
                  : _keys(ti, const [(0, 1), (.35, .4), (.7, 1.3), (1, 1)]);
              final iconRot = _heart
                  ? 0.0
                  : _keys(ti, const [(0, 0), (.35, 90), (.7, 180), (1, 180)]);

              // Le bouton, qui respire un instant après.
              final tb = running
                  ? ((ms - _fxStart) / _bumpMs).clamp(0.0, 1.0)
                  : 1.0;
              final btnScale = _keys(tb, [
                (0, 1),
                (.4, 1 + _bumpAmt),
                (.7, 1 - _bumpAmt * .3),
                (1, 1),
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
                        color: _heart ? null : const Color(0xFFF2F2F0),
                        gradient: _heart
                            ? const LinearGradient(
                                begin: Alignment(-.34, -.94),
                                end: Alignment(.34, .94),
                                colors: [Color(0xFFFF7D97), Color(0xFFE8385F)],
                              )
                            : null,
                        boxShadow: [
                          BoxShadow(
                            color: _heart
                                ? const Color(0xFFE8385F).withValues(alpha: .45)
                                : Colors.black.withValues(alpha: .45),
                            blurRadius: _heart ? 22 : 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Transform.rotate(
                        angle: iconRot * math.pi / 180,
                        child: Transform.scale(
                          scale: iconScale,
                          child: CustomPaint(
                            size: Size.square((_heart ? 32 : 28) * s / 76),
                            painter: _IconPainter(widget.kind),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (running && ms >= _fxStart)
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size.square(s),
                        painter: _FxPainter(
                          elapsedMs: ms - _fxStart,
                          color: _rippleColor,
                          particleColor: const Color(0xFFFF6B8A),
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

  final Fx2bKind kind;

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
    if (kind == Fx2bKind.heart) {
      canvas.drawPath(_heart(), Paint()..color = Colors.white);
    } else {
      canvas.drawPath(
        _cross(),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.4
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF1B1B1E),
      );
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.kind != kind;
}

class _FxPainter extends CustomPainter {
  _FxPainter({
    required this.elapsedMs,
    required this.color,
    required this.particleColor,
    required this.particles,
    required this.radius,
    required this.burstEase,
  });

  final double elapsedMs;
  final Color color;
  final Color particleColor;
  final List<_Particle> particles;
  final double radius;
  final Curve burstEase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    // Onde réduite : anneau 1 px, échelle 1 → 1.3, opacité .5 → 0 en 480 ms.
    final rp = (elapsedMs / 480).clamp(0.0, 1.0);
    if (rp < 1) {
      final k = burstEase.transform(rp);
      canvas.drawCircle(
        center,
        radius * (1 + .3 * k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: color.a * .5 * (1 - k)),
      );
    }

    // Particules (cœur) : 600 ms, s'éloignent en rétrécissant (1 → .2).
    final pp = (elapsedMs / 600).clamp(0.0, 1.0);
    if (pp < 1 && particles.isNotEmpty) {
      final k = burstEase.transform(pp);
      for (final p in particles) {
        final pos = center +
            Offset(math.cos(p.angle), math.sin(p.angle)) * (p.dist * k);
        final r = p.size / 2 * (1 - .8 * k);
        final a = 1 - k;
        canvas.drawCircle(
          pos,
          r,
          Paint()
            ..color = particleColor.withValues(alpha: .8 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawCircle(
          pos,
          r,
          Paint()..color = particleColor.withValues(alpha: a),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FxPainter old) => old.elapsedMs != elapsedMs;
}
