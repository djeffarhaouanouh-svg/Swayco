import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Le mot « swaycø » : police de marque, le « ø » à la moitié claire du
/// dégradé de marque (bleu → cyan), ou d'une couleur unie via [oColor].
class SwaycoWordmark extends StatelessWidget {
  const SwaycoWordmark({
    super.key,
    this.fontSize = 26,
    this.letterSpacing = 0.3,
    this.shadows,
    this.oColor,
  });

  final double fontSize;
  final double letterSpacing;
  final List<Shadow>? shadows;

  /// Couleur unie du « ø » à la place du dégradé — sur un fond déjà bleu
  /// (connexion), le dégradé s'y perdrait.
  final Color? oColor;

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
          if (oColor case final c?)
            TextSpan(
              text: 'ø',
              style: TextStyle(color: c),
            )
          else
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
