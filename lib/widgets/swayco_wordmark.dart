import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Brand lockup: `swaycø` then the coconut mark (ø in accent).
///
/// Icon size tracks [fontSize] so every placement stays coherent with the
/// surrounding text — ~1.05× the type size, optically matched to the
/// heavy weight of the wordmark. Mark sits **after** the letters.
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

  /// Coconut mark asset (transparent PNG).
  static const asset = 'assets/icons/swayco_coconut_mark.png';

  /// Icon edge length paired with a given wordmark [fontSize].
  static double iconSizeFor(double fontSize) => fontSize * 1.05;

  /// Gap between text and mark.
  static double gapFor(double fontSize) => (fontSize * 0.22).clamp(3.0, 8.0);

  /// Approximate laid-out width ("swaycø" + gap + mark) for collision math.
  static double widthFor(double fontSize, {double letterSpacing = 0.3}) {
    final icon = iconSizeFor(fontSize);
    final gap = gapFor(fontSize);
    final textW = (TextPainter(
      text: TextSpan(
        text: 'swaycø',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: letterSpacing,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout())
        .width;
    return textW + gap + icon;
  }

  @override
  Widget build(BuildContext context) {
    final icon = iconSizeFor(fontSize);
    final gap = gapFor(fontSize);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: 'swayc', style: TextStyle(color: color)),
              TextSpan(
                text: 'ø',
                style: TextStyle(color: SC.accent),
              ),
            ],
          ),
          maxLines: 1,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: letterSpacing,
            height: 1.0,
            shadows: shadows,
          ),
        ),
        SizedBox(width: gap),
        Image.asset(
          asset,
          width: icon,
          height: icon,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, _, _) => SizedBox(width: icon, height: icon),
        ),
      ],
    );
    if (opacity >= 1) return child;
    return Opacity(opacity: opacity, child: child);
  }
}
