import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Wordmark Swayco — variante 6d.
///
/// C'est le PNG du designer (`assets/swayco_logo_6d.png`, fond transparent,
/// mot blanc + "ø" cyan), et pas un dessin refait au widget : l'anneau barré
/// ne se retrouve pas à coups de ratios, chaque tentative retombait sur un
/// panneau d'interdiction. L'image fait foi.
///
/// Le logo est blanc : il n'existe que sur les fonds sombres de l'app.
class SwaycoLogo extends StatelessWidget {
  const SwaycoLogo({
    super.key,
    this.fontSize = 23,
    this.shadows = const <Shadow>[],
  });

  /// Taille du mot en px logiques, dans la continuité du wordmark texte qu'il
  /// remplace : 23 = l'en-tête Discover. Ce n'est plus une taille de police,
  /// c'est l'em avec lequel le PNG a été composé — la hauteur réelle du
  /// dessin en découle par [_heightPerEm].
  final double fontSize;

  /// Ombres portées — le logo posé sur une vidéo (l'appel) en a besoin pour
  /// rester lisible sur un fond clair. Peintes comme une silhouette floutée
  /// derrière le dessin, donc elles habillent le mot ET l'anneau.
  final List<Shadow> shadows;

  static const String _asset = 'assets/swayco_logo_6d.png';

  /// Le PNG (1354 × 291 après recadrage sur ses marges transparentes) a été
  /// composé à un em de ~378 px : le mot y mesure 286 px du haut d'x au bas
  /// du "y", soit les 0,756 em que valent la hauteur d'x et la descendante de
  /// Plus Jakarta. D'où hauteur du dessin ÷ em = 291/378.
  static const double _heightPerEm = 0.77;
  static const double _aspect = 1354 / 291;

  @override
  Widget build(BuildContext context) {
    final height = fontSize * _heightPerEm;
    final width = height * _aspect;

    // Le fichier source est 15× plus large que son rendu : sans cette
    // consigne, Flutter décode 1,5 Mpx pour peindre 80 px de large.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (width * dpr).round();

    final Widget mark = Image.asset(
      _asset,
      width: width,
      height: height,
      fit: BoxFit.contain,
      cacheWidth: cacheWidth,
      filterQuality: FilterQuality.medium,
    );

    if (shadows.isEmpty) return mark;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final s in shadows)
          Transform.translate(
            offset: s.offset,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: Shadow.convertRadiusToSigma(s.blurRadius),
                sigmaY: Shadow.convertRadiusToSigma(s.blurRadius),
              ),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(s.color, BlendMode.srcATop),
                child: Image.asset(
                  _asset,
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                  cacheWidth: cacheWidth,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        mark,
      ],
    );
  }
}
