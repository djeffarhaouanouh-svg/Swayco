import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// Qui porte la pastille. Décision produit : tout le monde, pour l'instant.
/// Les écrans passent ce réglage à `showSeal` ; le jour où elle se restreint,
/// c'est ici (et à la donnée qu'il faudra alors lire) que ça change.
const bool kSealOnEveryProfile = true;

/// La pastille : un rond en dégradé de marque avec son icône. Pas de texte —
/// seulement un libellé d'accessibilité.
class SwaycoSeal extends StatelessWidget {
  const SwaycoSeal({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppStrings.t('seal_label'),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: SC.brandGradient,
        ),
        child: Icon(
          Icons.verified_rounded,
          size: size * 0.72,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// La pastille dans une capsule de verre (34) : en haut à gauche d'une carte
/// Discover, et centrée sous une grande photo de profil (100 et plus).
///
/// Avec [label], le mot s'écrit à côté de la coche (carte Discover) ; sans, la
/// capsule est un rond avec la coche seule.
class SwaycoSealCapsule extends StatelessWidget {
  const SwaycoSealCapsule({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final text = label;
    final decoration = BoxDecoration(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(
        color: Colors.white.withValues(alpha: 0.30),
        width: 1.2,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: text == null
            ? Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: decoration,
                child: const SwaycoSeal(size: 20),
              )
            : Container(
                height: 34,
                padding: const EdgeInsets.only(left: 7, right: 12),
                decoration: decoration,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Le mot dit déjà ce que dit la coche.
                    const ExcludeSemantics(child: SwaycoSeal(size: 20)),
                    const SizedBox(width: 6),
                    Text(
                      text,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                        height: 1,
                        // Lisible aussi sur une photo claire.
                        shadows: [
                          Shadow(color: Color(0x66000000), blurRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// La pastille seule, posée sur le coin d'une petite photo de profil (listes,
/// moins de 100) : 18, cerclée de 2 px de la couleur du fond de la ligne pour
/// qu'elle paraisse découpée dans la photo.
class SwaycoSealCorner extends StatelessWidget {
  const SwaycoSealCorner({super.key, required this.ringColor});

  final Color ringColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: ringColor, shape: BoxShape.circle),
      child: const SwaycoSeal(size: 18),
    );
  }
}
