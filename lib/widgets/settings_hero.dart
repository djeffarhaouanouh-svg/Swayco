import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Place du rond « retour » des Réglages, comptée depuis le bord gauche : celle
/// du bouton retour de l'AppBar (14 de marge).
const double _kBackLeft = 14;

/// Les Réglages apparaissent en fondu : le rond est DÉJÀ arrivé à la place de
/// leur bouton retour, la page n'a rien d'autre à animer.
Route<T> settingsHeroRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (_, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

/// Le rond « engrenage » du profil. Au tap, il glisse seul jusqu'à la place
/// du bouton retour en roulant sur lui-même — l'engrenage devient flèche en
/// chemin. Il s'y POSE, et seulement alors la page des Réglages s'ouvre
/// ([onOpen]). De retour sur le profil, il repart à sa place.
///
/// Deux temps distincts, et non un « vol » de Hero : un Hero suit la courbe de
/// la transition de page, et le rond filait d'un coup comme une étoile
/// filante au lieu de se déplacer.
class SettingsHeroButton extends StatefulWidget {
  const SettingsHeroButton({super.key, required this.onOpen});

  /// Ouvre la page ; la future se termine quand on revient sur le profil.
  final Future<void> Function() onOpen;

  @override
  State<SettingsHeroButton> createState() => _SettingsHeroButtonState();
}

class _SettingsHeroButtonState extends State<SettingsHeroButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  bool _busy = false;
  double _distance = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    _busy = true;
    // Distance jusqu'à la place du retour, mesurée sur l'écran.
    _distance = box.localToGlobal(Offset.zero).dx - _kBackLeft;
    // 1. Le rond se déplace et arrive.
    await _c.forward(from: 0);
    if (!mounted) return;
    // 2. Un temps de pose, posé à destination.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    // 3. Puis la page.
    await widget.onOpen();
    if (!mounted) return;
    // Retour sur le profil : il repart à sa place.
    await _c.reverse();
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _go,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = Curves.easeInOutCubic.transform(_c.value);
          return Transform.translate(
            offset: Offset(-_distance * t, 0),
            child: SettingsDisc(t: t),
          );
        },
      ),
    );
  }
}

/// Le rond de verre (44). [t] 0 = engrenage, 1 = flèche retour ; entre les
/// deux, il roule (un demi-tour vers la gauche) et les icônes se fondent.
class SettingsDisc extends StatelessWidget {
  const SettingsDisc({super.key, required this.t});

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

/// Le bouton retour des Réglages : le même rond, déjà en flèche, exactement
/// là où le rond du profil vient de se poser.
class SettingsBackButton extends StatelessWidget {
  const SettingsBackButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const SettingsDisc(t: 1),
    );
  }
}
