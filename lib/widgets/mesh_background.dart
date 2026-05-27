import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Midnight ambient background — Swayco's exported mesh PNG, stretched
/// to fill the screen with a soft vignette on top for legibility. Drop
/// it just inside [Scaffold.body] when the scaffold's own background is
/// transparent. The PNG sits on top of [SC.bg] so the navy fills any
/// uncovered area while the asset is loading.
class MeshBackground extends StatelessWidget {
  const MeshBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SC.bg,
      child: Stack(
        children: [
          // Designer-exported mesh (blue / violet / cyan / navy halos).
          // We force the canvas to a landscape aspect so BoxFit.cover
          // always crops the violet/cyan halos top & bottom and only
          // the dark middle band shows through — same look on a 390-wide
          // phone and a 1440-wide desktop window.
          Positioned.fill(
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const minAspect = 16 / 9;
                  final h = constraints.maxHeight;
                  final w = constraints.maxWidth;
                  final canvasW =
                      (w / h) < minAspect ? h * minAspect : w;
                  return OverflowBox(
                    minWidth: canvasW,
                    maxWidth: canvasW,
                    minHeight: h,
                    maxHeight: h,
                    child: Image.asset(
                      'assets/mesh_midnight_bg.png',
                      fit: BoxFit.cover,
                      // If the asset is missing we silently keep the
                      // navy base — better than crashing the screen.
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  );
                },
              ),
            ),
          ),
          // Vignette: nudges contrast up at the edges without going pitch black.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 1.2,
                  colors: [Colors.transparent, Color(0x33000000)],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
