import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// État visuel de la pierre.
enum SwayStoneMode {
  /// Iridescente, ondes qui partent, barres audio au centre. (8a)
  listening,

  /// Traduction en pause : verre dépoli, pointillés, ▶. (8b)
  paused,

  /// Réduite, avec une icône au centre au lieu des barres. (8d)
  compact,
}

/// Le « bouton audio » de swaycø.
///
/// Tap = couper / reprendre la traduction.
/// Appui long = ouvrir les langues / le son.
///
/// ```dart
/// SwayStone(
///   size: 130,
///   mode: _paused ? SwayStoneMode.paused : SwayStoneMode.listening,
///   onTap: _toggleTranslation,
///   onLongPress: _openCallSettingsSheet,
/// )
/// ```
class SwayStone extends StatefulWidget {
  const SwayStone({
    super.key,
    this.size = 130,
    this.mode = SwayStoneMode.listening,
    this.onTap,
    this.onLongPress,
    this.compactIcon = Icons.graphic_eq_rounded,
    this.float = true,
    this.ripples = true,
  });

  final double size;
  final SwayStoneMode mode;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Icône affichée au centre en mode [SwayStoneMode.compact].
  final IconData compactIcon;

  /// Lévitation verticale lente.
  final bool float;

  /// Ondes concentriques (mode listening uniquement).
  final bool ripples;

  @override
  State<SwayStone> createState() => _SwayStoneState();
}

class _SwayStoneState extends State<SwayStone> with TickerProviderStateMixin {
  late final AnimationController _spin;    // rotation du dégradé iridescent
  late final AnimationController _sheen;   // reflet qui tourne sur le bord
  late final AnimationController _floatC;  // lévitation
  late final AnimationController _breathe; // halo qui respire
  late final AnimationController _ripple;  // ondes
  late final AnimationController _bars;    // barres audio

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 9000))..repeat();
    _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 5000))..repeat();
    _floatC = AnimationController(vsync: this, duration: const Duration(milliseconds: 6500))..repeat(reverse: true);
    _breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 3800))..repeat(reverse: true);
    _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 3400))..repeat();
    _bars = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
  }

  @override
  void dispose() {
    for (final c in [_spin, _sheen, _floatC, _breathe, _ripple, _bars]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _alive => widget.mode != SwayStoneMode.paused;

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    // Le halo dépasse le disque : on réserve de la marge autour.
    final box = s * 1.9;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: Listenable.merge([_spin, _sheen, _floatC, _breathe, _ripple, _bars]),
        builder: (context, _) {
          final float = widget.float
              ? -13.0 * Curves.easeInOut.transform(_floatC.value)
              : 0.0;

          return SizedBox(
            width: box,
            height: box,
            child: Transform.translate(
              offset: Offset(0, float),
              child: Center(
                child: SizedBox(
                  width: s,
                  height: s,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      if (_alive && widget.ripples) ..._buildRipples(s),
                      if (_alive) _buildHalo(s),
                      if (_alive) _buildIridescence(s) else _buildFrosted(s),
                      if (_alive) _buildGlass(s),
                      if (_alive) _buildSheen(s),
                      _buildCore(s),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Ondes concentriques ────────────────────────────────────────────────
  List<Widget> _buildRipples(double s) {
    const colors = [Color(0xFFC9B7FF), Color(0xFF5FE3D0)];
    return List.generate(2, (i) {
      final t = (_ripple.value + i * 0.5) % 1.0;
      final e = Curves.easeOut.transform(t);
      return Opacity(
        opacity: (1 - e) * 0.5,
        child: Transform.scale(
          scale: 1 + e * 1.4,
          child: Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: colors[i], width: 1),
            ),
          ),
        ),
      );
    });
  }

  // ── Halo qui respire ───────────────────────────────────────────────────
  Widget _buildHalo(double s) {
    final b = Curves.easeInOut.transform(_breathe.value);
    return Opacity(
      opacity: 0.5 + 0.5 * b,
      child: Transform.scale(
        scale: 0.97 + 0.06 * b,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 11, sigmaY: 11),
          child: Container(
            width: s * 1.28,
            height: s * 1.28,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Color(0x6BC9B7FF),
                  Color(0x295FE3D0),
                  Color(0x00000000),
                ],
                stops: [0.0, 0.56, 0.74],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Anneau iridescent (conic-gradient flouté) ──────────────────────────
  Widget _buildIridescence(double s) {
    return Opacity(
      opacity: 0.9,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
        child: Transform.rotate(
          angle: _spin.value * 2 * math.pi,
          child: Container(
            width: s,
            height: s,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Color(0xFF5FE3D0),
                  Color(0xFF7AA2FF),
                  Color(0xFFC9B7FF),
                  Color(0xFFFF9EC4),
                  Color(0xFFFFD479),
                  Color(0xFF5FE3D0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Verre dépoli (mode pause) ──────────────────────────────────────────
  Widget _buildFrosted(double s) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: CustomPaint(
          size: Size(s, s),
          painter: _DashedRingPainter(color: Colors.white.withOpacity(0.34)),
          child: Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.10),
            ),
          ),
        ),
      ),
    );
  }

  // ── Bille de verre intérieure ──────────────────────────────────────────
  Widget _buildGlass(double s) {
    final inset = s * 0.069; // 9px sur 130
    return Container(
      width: s - inset * 2,
      height: s - inset * 2,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: Alignment(-0.32, -0.48), // « 34% 26% »
          radius: 0.95,
          colors: [
            Color(0xF2FFFFFF),
            Color(0x4DFFFFFF),
            Color(0x0DFFFFFF),
            Color(0x21FFFFFF),
          ],
          stops: [0.0, 0.26, 0.54, 1.0],
        ),
      ),
      // Faux inner-shadow : lumière en haut, bleu profond en bas.
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: Alignment(0, 1.05),
            radius: 0.9,
            colors: [Color(0x597AA2FF), Color(0x00000000)],
          ),
        ),
      ),
    );
  }

  // ── Reflet qui balaie le bord ──────────────────────────────────────────
  Widget _buildSheen(double s) {
    final inset = s * 0.069;
    return Transform.rotate(
      angle: _sheen.value * 2 * math.pi + math.pi * 7 / 6, // départ ~210°
      child: CustomPaint(
        size: Size(s - inset * 2, s - inset * 2),
        painter: _SheenPainter(),
      ),
    );
  }

  // ── Centre : barres audio, ▶ ou icône ──────────────────────────────────
  Widget _buildCore(double s) {
    switch (widget.mode) {
      case SwayStoneMode.paused:
        return Icon(
          Icons.play_arrow_rounded,
          size: s * 0.29,
          color: Colors.white.withOpacity(0.5),
        );
      case SwayStoneMode.compact:
        return Icon(
          widget.compactIcon,
          size: s * 0.29,
          color: Colors.white.withOpacity(0.9),
        );
      case SwayStoneMode.listening:
        return _buildBars(s);
    }
  }

  Widget _buildBars(double s) {
    const heights = [12.0, 22.0, 30.0, 18.0]; // sur une pierre de 130
    const delays = [0.0, 0.12, 0.24, 0.36];
    final k = s / 130.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(heights.length, (i) {
        // Phase décalée par barre, va-et-vient 0.35 → 1.0.
        final t = (_bars.value + delays[i]) % 1.0;
        final wave = math.sin(t * math.pi); // 0 → 1 → 0
        final scale = 0.35 + 0.65 * wave;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: 2 * k),
          child: Container(
            width: 3.5 * k,
            height: heights[i] * k * scale,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.95),
              borderRadius: BorderRadius.circular(2 * k),
            ),
          ),
        );
      }),
    );
  }
}

// ── Peintres ─────────────────────────────────────────────────────────────

class _SheenPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = size.width * 0.09;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..shader = const SweepGradient(
        colors: [
          Color(0x00FFFFFF),
          Color(0xB3FFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: [0.0, 0.5, 1.0],
      ).createShader(rect);

    canvas.drawCircle(
      rect.center,
      (size.width - stroke) / 2,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SheenPainter oldDelegate) => false;
}

class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..color = color;

    final r = (size.width - 1) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    const dash = 0.10; // rad
    const gap = 0.075;

    double a = 0;
    while (a < 2 * math.pi) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        a,
        dash,
        false,
        paint,
      );
      a += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRingPainter oldDelegate) =>
      oldDelegate.color != color;
}
