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
    this.adaptive = false,
  });

  final double fontSize;
  final double letterSpacing;
  final List<Shadow>? shadows;

  /// Couleur unie du « ø » à la place du dégradé — sur un fond déjà bleu
  /// (connexion), le dégradé s'y perdrait.
  final Color? oColor;

  /// Suit le thème : en mode clair, « swayc » en encre et « ø » en bleu (le
  /// blanc et le jaune seraient illisibles sur blanc). Faux sur les écrans
  /// de marque (connexion, splash, appel) qui restent sur fond bleu / sombre.
  final bool adaptive;

  static const _oGradient = LinearGradient(
    begin: Alignment(-0.6, -1),
    end: Alignment(0.6, 1),
    colors: [SC.brandBlue, SC.brandCyan],
  );

  @override
  Widget build(BuildContext context) {
    final onLight = adaptive && SC.light;
    final Color? effO = oColor ?? (onLight ? SC.brandBlueDeep : null);
    final style = TextStyle(
      color: onLight ? SC.textPrimary : Colors.white,
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
          if (effO case final c?)
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
