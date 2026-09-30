import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Le mot « swaycø » : police de marque, le « ø » à la moitié claire du
/// dégradé de marque (bleu → cyan).
class SwaycoWordmark extends StatelessWidget {
  const SwaycoWordmark({
    super.key,
    this.fontSize = 26,
    this.letterSpacing = 0.3,
    this.shadows,
  });

  final double fontSize;
  final double letterSpacing;
  final List<Shadow>? shadows;

  static const _oGradient = LinearGradient(
    begin: Alignment(-0.6, -1),
    end: Alignment(0.6, 1),
    colors: [SC.brandBlue, SC.brandCyan],
  );

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Colors.white,
      fontFamily: SC.brandFont,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: letterSpacing,
      shadows: shadows,
    );
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'swayc'),
          // Un shader de TextSpan se cale sur le paragraphe entier, pas sur
          // le glyphe : le masque est posé sur le « ø » seul. Sans ombre :
          // srcIn la teinterait en halo coloré.
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: _oGradient.createShader,
              child: Text('ø', style: style.copyWith(shadows: const [])),
            ),
          ),
        ],
      ),
      style: style,
    );
  }
}
