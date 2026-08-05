import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// The `swaycø` wordmark — plain type, the "ø" in [SC.brandO].
///
/// Single source of truth for the brand type so a weight / colour tweak lands
/// everywhere at once (Discover, Messages, chat header, in-call watermark).
class SwaycoWordmark extends StatelessWidget {
  const SwaycoWordmark({
    super.key,
    this.fontSize = 22,
    this.color = Colors.white,
    this.letterSpacing = 0.3,
    this.shadows,
    this.opacity = 1,
  });

  final double fontSize;
  final Color color;
  final double letterSpacing;
  final List<Shadow>? shadows;
  final double opacity;

  static TextStyle styleFor(
    double fontSize, {
    double letterSpacing = 0.3,
    List<Shadow>? shadows,
  }) =>
      TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        letterSpacing: letterSpacing,
        height: 1.0,
        shadows: shadows,
      );

  /// Laid-out width of "swaycø" — used by the chat header collision math.
  static double widthFor(double fontSize, {double letterSpacing = 0.3}) =>
      (TextPainter(
        text: TextSpan(
          text: 'swaycø',
          style: styleFor(fontSize, letterSpacing: letterSpacing),
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout())
          .width;

  @override
  Widget build(BuildContext context) {
    final child = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'swayc', style: TextStyle(color: color)),
          const TextSpan(
            text: 'ø',
            style: TextStyle(color: SC.brandO),
          ),
        ],
      ),
      maxLines: 1,
      style: styleFor(
        fontSize,
        letterSpacing: letterSpacing,
        shadows: shadows,
      ),
    );
    if (opacity >= 1) return child;
    return Opacity(opacity: opacity, child: child);
  }
}
