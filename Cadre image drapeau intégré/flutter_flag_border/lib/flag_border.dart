import 'package:flutter/material.dart';
import 'flag_gradients.dart';

/// Contour « 2a » : un fin liseré dégradé aux couleurs du drapeau, avec une
/// légère lueur, qui enveloppe n'importe quel contenu (photo, carte…).
///
/// ⚠️ Ce widget ne dessine QUE le contour. L'intérieur de la carte (photo,
/// nom, âge, ville, etc.) reste entièrement de ton côté : passe-le via [child].
///
/// ```dart
/// FlagBorder(
///   country: FlagCountry.portugal,
///   child: MonContenuDeCarte(), // photo + overlay, géré par toi
/// )
/// ```
class FlagBorder extends StatelessWidget {
  /// Le contenu de la carte (géré par ton app). Il est simplement rogné aux
  /// coins arrondis, à l'intérieur du liseré.
  final Widget child;

  /// Le pays dont on veut le contour.
  final FlagCountry country;

  /// Épaisseur du liseré, en px logiques. (design 2a : 2.0)
  final double borderWidth;

  /// Rayon des coins extérieurs. (design 2a : 28.0)
  final double radius;

  /// Rayon de flou de la lueur autour du contour. (design 2a : 30.0)
  final double glowBlur;

  /// Affiche (ou non) l'ombre portée sous la carte. (design 2a : activée)
  final bool dropShadow;

  const FlagBorder({
    super.key,
    required this.child,
    required this.country,
    this.borderWidth = 2.0,
    this.radius = 28.0,
    this.glowBlur = 30.0,
    this.dropShadow = true,
  });

  @override
  Widget build(BuildContext context) {
    final g = kFlagGradients[country]!;

    return Container(
      padding: EdgeInsets.all(borderWidth),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          // ≈ 145° en CSS → diagonale haut-gauche vers bas-droit.
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g.colors,
          stops: g.stops,
        ),
        boxShadow: [
          BoxShadow(color: g.glow, blurRadius: glowBlur),
          if (dropShadow)
            const BoxShadow(
              color: Color(0x8C000000),
              blurRadius: 44,
              offset: Offset(0, 18),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - borderWidth),
        child: child,
      ),
    );
  }
}
