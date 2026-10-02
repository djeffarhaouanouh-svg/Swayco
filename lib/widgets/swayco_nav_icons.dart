// swayco_nav_icons.dart — à poser dans lib/widgets/
//
// Icônes de la barre du bas, variante B « Plein arrondi ».
// Dessinées au Path (comme ton Fx2bButton) : pas de SVG, pas d'asset, une seule
// couleur. Aucune API plus récente que Flutter 3.41.2.

import 'dart:math' as math;

import 'package:flutter/material.dart';

enum SwaycoNavKind { chat, discover, requests, profile }

class SwaycoNavIcon extends StatelessWidget {
  const SwaycoNavIcon({
    super.key,
    required this.kind,
    required this.color,
    this.size = 22,
  });

  final SwaycoNavKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _NavIconPainter(kind, color)),
    );
  }
}

class _NavIconPainter extends CustomPainter {
  _NavIconPainter(this.kind, this.color);

  final SwaycoNavKind kind;
  final Color color;

  // Cœur, viewBox 24×24.
  static Path _heart() => Path()
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

  // Bulle de chat avec trois points évidés.
  static Path _chat() {
    final body = Path()
      ..addRRect(
        RRect.fromLTRBR(3, 3.5, 21, 16.5, const Radius.circular(3.5)),
      );
    final tail = Path()
      ..moveTo(7.8, 15.8)
      ..lineTo(7.8, 19.85)
      ..quadraticBezierTo(7.8, 20.3, 8.2, 19.95)
      ..lineTo(12.8, 15.8)
      ..close();
    final shape = Path.combine(PathOperation.union, body, tail);
    final dots = Path();
    for (final x in const [8.5, 12.0, 15.5]) {
      dots.addOval(Rect.fromCircle(center: Offset(x, 10), radius: 1.1));
    }
    return Path.combine(PathOperation.difference, shape, dots);
  }

  // Deux cartes : celle de devant pleine, celle de derrière inclinée.
  // Retourne (derrière, devant) ; la carte de derrière est évidée autour de
  // celle de devant pour laisser un filet de fond entre les deux.
  static (Path, Path) _cards() {
    final front = Path()
      ..addRRect(
        RRect.fromLTRBR(8.5, 3.5, 20.5, 20.5, const Radius.circular(3.5)),
      );
    var back = Path()
      ..addRRect(RRect.fromLTRBR(3, 6, 13, 20, const Radius.circular(3)));
    final m = Matrix4.translationValues(8.0, 13.0, 0) *
        Matrix4.rotationZ(-8 * math.pi / 180) *
        Matrix4.translationValues(-8.0, -13.0, 0);
    back = back.transform(m.storage);
    final gap = Path()
      ..addRRect(
        RRect.fromLTRBR(7.75, 2.75, 21.25, 21.25, const Radius.circular(4.25)),
      );
    return (Path.combine(PathOperation.difference, back, gap), front);
  }

  static Path _profile() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 8), radius: 4))
    ..moveTo(4.5, 20.5)
    ..cubicTo(4.5, 16.6, 7.6, 14, 12, 14)
    ..cubicTo(16.4, 14, 19.5, 16.6, 19.5, 20.5)
    ..cubicTo(19.5, 21.1, 19.1, 21.5, 18.5, 21.5)
    ..lineTo(5.5, 21.5)
    ..cubicTo(4.9, 21.5, 4.5, 21.1, 4.5, 20.5)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    switch (kind) {
      case SwaycoNavKind.chat:
        canvas.drawPath(_chat(), paint);
      case SwaycoNavKind.discover:
        final (back, front) = _cards();
        canvas.drawPath(
          back,
          Paint()
            ..color = color.withValues(alpha: color.a * 0.55)
            ..isAntiAlias = true,
        );
        canvas.drawPath(front, paint);
      case SwaycoNavKind.requests:
        canvas.drawPath(_heart(), paint);
      case SwaycoNavKind.profile:
        canvas.drawPath(_profile(), paint);
    }
  }

  @override
  bool shouldRepaint(_NavIconPainter old) =>
      old.kind != kind || old.color != color;
}
