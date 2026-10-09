// swayco_action_buttons.dart — à poser dans lib/widgets/
//
// Bouton cœur (vert) et bouton croix (blanc), effet bombé : dégradé radial
// avec reflet en haut à gauche. Sans asset ni dépendance.
//
// Usage :
//   SwaycoCrossButton(onTap: _pass),
//   SwaycoHeartButton(onTap: _like),

import 'package:flutter/material.dart';

class _DomeButton extends StatefulWidget {
  const _DomeButton({
    required this.size,
    required this.colors,
    required this.shadow,
    required this.icon,
    required this.onTap,
  });

  final double size;
  final List<Color> colors;
  final Color shadow;
  final Widget icon;
  final VoidCallback? onTap;

  @override
  State<_DomeButton> createState() => _DomeButtonState();
}

class _DomeButtonState extends State<_DomeButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 1.12 : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutBack,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.5),
              radius: 0.95,
              colors: widget.colors,
              stops: const [0.0, 0.35, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: widget.shadow,
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: widget.icon,
        ),
      ),
    );
  }
}

/// Cœur blanc sur rond vert bombé.
class SwaycoHeartButton extends StatelessWidget {
  const SwaycoHeartButton({super.key, this.onTap, this.size = 76});

  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return _DomeButton(
      size: size,
      onTap: onTap,
      colors: const [Color(0xFF7BF0B4), Color(0xFF2FD486), Color(0xFF0F9A55)],
      shadow: const Color(0x80129E58),
      icon: CustomPaint(
        size: Size.square(size * 0.45),
        painter: _HeartPainter(Colors.white),
      ),
    );
  }
}

/// Croix sombre sur rond blanc bombé.
class SwaycoCrossButton extends StatelessWidget {
  const SwaycoCrossButton({super.key, this.onTap, this.size = 76});

  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return _DomeButton(
      size: size,
      onTap: onTap,
      colors: const [Colors.white, Color(0xFFF1F1EF), Color(0xFFB9B9B4)],
      shadow: const Color(0x80000000),
      icon: CustomPaint(
        size: Size.square(size * 0.40),
        painter: _CrossPainter(const Color(0xFF1A1A1A)),
      ),
    );
  }
}

class _HeartPainter extends CustomPainter {
  _HeartPainter(this.color);

  final Color color;

  // Cœur dessiné dans un viewBox 24×24 (zone utile : x 3.5→20.5, y 5.5→20).
  static Path _path() => Path()
    ..moveTo(12, 20)
    ..cubicTo(11.7, 20, 11.5, 19.9, 11.3, 19.7)
    ..cubicTo(6.6, 16, 3.5, 13.2, 3.5, 9.6)
    ..cubicTo(3.5, 7.2, 5.3, 5.5, 7.6, 5.5)
    ..cubicTo(9.3, 5.5, 10.7, 6.4, 12, 8)
    ..cubicTo(13.3, 6.4, 14.7, 5.5, 16.4, 5.5)
    ..cubicTo(18.7, 5.5, 20.5, 7.2, 20.5, 9.6)
    ..cubicTo(20.5, 13.2, 17.4, 16, 12.7, 19.7)
    ..cubicTo(12.5, 19.9, 12.3, 20, 12, 20)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 17; // largeur utile : 17 unités
    canvas.scale(s, s);
    // Centre la zone utile (centre x 12, centre y 12.75) dans la case.
    canvas.translate(8.5 - 12, 8.5 - 12.75);
    canvas.drawPath(_path(), Paint()
      ..color = color
      ..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(_HeartPainter old) => old.color != color;
}

class _CrossPainter extends CustomPainter {
  _CrossPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final m = size.width * 0.1;
    canvas.drawLine(Offset(m, m), Offset(size.width - m, size.height - m), p);
    canvas.drawLine(Offset(size.width - m, m), Offset(m, size.height - m), p);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.color != color;
}
