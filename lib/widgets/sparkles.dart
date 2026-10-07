import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Etincelles qui scintillent par-dessus un bouton (ceux qui menent a un
/// paywall) : de petites etoiles a quatre branches qui s'allument et
/// s'eteignent chacune a son rythme, coupees au contour du bouton, plus une
/// etincelle jaune qui deborde du coin haut droit.
///
/// Purement decoratif : ne prend aucun appui, et reste fixe (etoiles faibles)
/// quand les animations sont reduites.
class Sparkles extends StatefulWidget {
  const Sparkles({
    super.key,
    required this.child,
    this.borderRadius = 999,
    this.color = Colors.white,
    this.count = 6,
    this.corner = true,
  });

  final Widget child;

  /// Rayon du contour du bouton : les etoiles y sont coupees.
  final double borderRadius;

  /// Couleur des etoiles (blanc sur un fond de marque, bleu nuit sur le jaune).
  final Color color;

  /// Nombre d'etoiles dans le bouton (2 a 10).
  final int count;

  /// Etincelle jaune qui deborde du coin haut droit.
  final bool corner;

  @override
  State<Sparkles> createState() => _SparklesState();
}

class _SparklesState extends State<Sparkles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!MediaQuery.disableAnimationsOf(context)) _ctl.repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: CustomPaint(
                painter: _SparklePainter(
                  _ctl,
                  widget.color,
                  widget.count.clamp(2, 10),
                ),
              ),
            ),
          ),
        ),
        if (widget.corner)
          Positioned(
            top: -7,
            right: -5,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctl,
                builder: (_, _) {
                  final p = _twinkle(_ctl.value, 0.15, 1);
                  return Opacity(
                    opacity: 0.35 + 0.65 * p,
                    child: Transform.scale(
                      scale: 0.7 + 0.5 * p,
                      child: CustomPaint(
                        size: const Size(15, 15),
                        painter: _StarPainter(SC.accent, 1),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// 0 -> 1 -> 0 en forme de cloche, une fois par tour, decale de [phase].
double _twinkle(double t, double phase, double speed) {
  final x = ((t * speed + phase) % 1.0);
  // Etincelle courte : allumee sur ~40 % du tour, eteinte le reste.
  if (x > 0.4) return 0;
  final s = math.sin(x / 0.4 * math.pi);
  return s * s;
}

class _SparklePainter extends CustomPainter {
  _SparklePainter(this.anim, this.color, this.count) : super(repaint: anim);

  final Animation<double> anim;
  final Color color;
  final int count;

  // (x, y, taille, phase, vitesse) : positions fixes, repartis sur le bouton.
  static const _spots = <List<double>>[
    [0.12, 0.30, 7, 0.00, 1],
    [0.30, 0.72, 5, 0.18, 1],
    [0.48, 0.25, 6, 0.42, 1],
    [0.64, 0.70, 8, 0.65, 1],
    [0.82, 0.32, 6, 0.30, 1],
    [0.92, 0.68, 5, 0.85, 1],
    [0.22, 0.50, 4, 0.55, 2],
    [0.72, 0.48, 4, 0.08, 2],
    [0.40, 0.55, 5, 0.75, 1],
    [0.58, 0.40, 4, 0.95, 2],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < count; i++) {
      final s = _spots[i];
      final p = _twinkle(anim.value, s[3], s[4]);
      if (p <= 0.02) continue;
      final r = s[2] * (0.5 + 0.7 * p);
      canvas.save();
      canvas.translate(size.width * s[0], size.height * s[1]);
      canvas.rotate(p * 0.6);
      _drawStar(canvas, r, color.withValues(alpha: 0.95 * p));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) =>
      old.color != color || old.count != count;
}

/// Etoile a quatre branches (losange concave) de rayon [r], centree en (0, 0).
void _drawStar(Canvas canvas, double r, Color color) {
  final inner = r * 0.28;
  final path = Path()
    ..moveTo(0, -r)
    ..quadraticBezierTo(inner, -inner, r, 0)
    ..quadraticBezierTo(inner, inner, 0, r)
    ..quadraticBezierTo(-inner, inner, -r, 0)
    ..quadraticBezierTo(-inner, -inner, 0, -r)
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

class _StarPainter extends CustomPainter {
  const _StarPainter(this.color, this.scale);

  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    // Petit halo puis l'etoile.
    canvas.drawCircle(
      Offset.zero,
      size.width * 0.5,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    _drawStar(canvas, size.width / 2 * scale, color);
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.color != color;
}
