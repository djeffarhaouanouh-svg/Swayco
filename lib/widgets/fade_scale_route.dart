import 'package:flutter/material.dart';

/// Une page qui apparaît SUR PLACE — fondu + très léger zoom (97 % → 100 %) —
/// au lieu de monter du bas. Même entrée que la pop-up globe de Discover.
Route<T> fadeScaleRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.97, end: 1.0)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}
