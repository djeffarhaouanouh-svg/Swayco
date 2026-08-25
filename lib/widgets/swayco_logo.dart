import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Wordmark Swayco — variante 6d.
/// Le mot est en Plus Jakarta Sans ExtraBold italique, légèrement penché ;
/// le "o" est un anneau cyan barré d'un trait en diagonale, resté droit.
///
/// pubspec.yaml :
///   fonts:
///     - family: PlusJakartaSans
///       fonts:
///         - asset: assets/fonts/PlusJakartaSans-ExtraBoldItalic.ttf
///           weight: 800
///           style: italic
class SwaycoLogo extends StatelessWidget {
  const SwaycoLogo({
    super.key,
    this.fontSize = 23,
    this.wordColor = Colors.white,
    this.accentColor = const Color(0xFF22C8DE),
    this.shadows = const <Shadow>[],
  });

  /// Taille du mot en px logiques. 23 correspond à l'en-tête Discover.
  final double fontSize;
  final Color wordColor;
  final Color accentColor;

  /// Ombres portées — le logo posé sur une vidéo (l'appel) en a besoin pour
  /// rester lisible sur un fond clair. Elles habillent le mot ET l'anneau,
  /// sinon le "ø" décrocherait du reste sur les images claires.
  final List<Shadow> shadows;

  @override
  Widget build(BuildContext context) {
    // Toutes les mesures sont proportionnelles à fontSize (ratios du design).
    final ringSize = fontSize * 0.522; // hauteur d'x
    final ringStroke = fontSize * 0.152;
    final barLength = fontSize * 0.609;
    final barThickness = fontSize * 0.109;
    final gap = fontSize * 0.065;

    final boxShadows = shadows
        .map((s) => BoxShadow(
              color: s.color,
              blurRadius: s.blurRadius,
              offset: s.offset,
            ))
        .toList(growable: false);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Transform(
          alignment: Alignment.bottomCenter,
          transform: Matrix4.skewX(-0.157), // -9°
          child: Text(
            'swayc',
            style: TextStyle(
              fontFamily: 'PlusJakartaSans',
              fontWeight: FontWeight.w800,
              fontStyle: FontStyle.italic,
              fontSize: fontSize,
              height: 1,
              letterSpacing: fontSize * -0.04,
              color: wordColor,
              shadows: shadows.isEmpty ? null : shadows,
            ),
          ),
        ),
        SizedBox(width: gap),
        Padding(
          // aligne l'anneau sur la ligne de base du mot
          padding: EdgeInsets.only(bottom: fontSize * 0.03),
          child: SizedBox(
            width: ringSize,
            height: ringSize,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: accentColor, width: ringStroke),
                    boxShadow: boxShadows.isEmpty ? null : boxShadows,
                  ),
                ),
                Transform.rotate(
                  angle: -math.pi / 4,
                  child: Container(
                    width: barLength,
                    height: barThickness,
                    decoration: BoxDecoration(
                      color: accentColor,
                      boxShadow: boxShadows.isEmpty ? null : boxShadows,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
