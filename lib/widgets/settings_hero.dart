import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Le rond « engrenage » du profil devient le rond « retour » des Réglages :
/// au tap, il glisse le long de la barre jusqu'à la place du bouton retour en
/// roulant sur lui-même, l'engrenage se change en flèche, PUIS la page des
/// Réglages apparaît (et l'inverse au retour).
const String settingsHeroTag = 'settings-gear-hero';

/// Durée totale : la première moitié pour le glissement, la seconde pour
/// l'apparition de la page.
const Duration _kDuration = Duration(milliseconds: 560);

/// Ouvre [builder] avec la transition « l'engrenage glisse puis la page
/// s'ouvre ».
Route<T> settingsHeroRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: _kDuration,
    reverseTransitionDuration: _kDuration,
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(
      // La page n'apparaît qu'une fois le rond arrivé (seconde moitié).
      opacity: CurvedAnimation(
        parent: anim,
        curve: const Interval(0.5, 1, curve: Curves.easeOut),
      ),
      child: child,
    ),
  );
}

/// Le rond de verre (44) partagé : engrenage sur le profil, flèche retour
/// dans les Réglages. [t] 0 = engrenage, 1 = flèche (le vol mélange les deux).
class SettingsHeroButton extends StatelessWidget {
  const SettingsHeroButton({super.key, required this.isBack, this.onTap});

  final bool isBack;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: settingsHeroTag,
      // Pendant le vol : le rond roule (un demi-tour vers la gauche) et
      // l'engrenage se fond en flèche.
      flightShuttleBuilder: (_, anim, direction, _, _) => AnimatedBuilder(
        animation: anim,
        builder: (_, _) => _GlassDisc(t: _firstHalf(anim.value)),
      ),
      // Trajet en ligne droite le long de la barre (pas l'arc Material),
      // bouclé dans la première moitié : la page s'ouvre ensuite.
      createRectTween: (a, b) => _FirstHalfRectTween(begin: a, end: b),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: _GlassDisc(t: isBack ? 1 : 0),
      ),
    );
  }
}

/// 0 → 0,5 de l'animation de la route ramené sur 0 → 1 (le reste : arrivé).
double _firstHalf(double v) =>
    Curves.easeInOut.transform((v * 2).clamp(0.0, 1.0));

class _FirstHalfRectTween extends RectTween {
  _FirstHalfRectTween({super.begin, super.end});

  @override
  Rect? lerp(double t) => super.lerp(_firstHalf(t));
}

class _GlassDisc extends StatelessWidget {
  const _GlassDisc({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.13),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
                width: 1.2,
              ),
            ),
            child: Transform.rotate(
              // Il roule vers la gauche en glissant.
              angle: -t * math.pi,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: (1 - t * 1.6).clamp(0.0, 1.0),
                    child: const Icon(
                      Icons.settings_outlined,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                  Opacity(
                    opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
                    // Contre-rotation : la flèche arrive à l'endroit.
                    child: Transform.rotate(
                      angle: t * math.pi,
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
