import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Midnight ambient background — a solid navy [SC.bg] fill with a soft
/// vignette on top for legibility. Drop it just inside [Scaffold.body]
/// when the scaffold's own background is transparent.
class MeshBackground extends StatelessWidget {
  const MeshBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SC.bg,
      child: Stack(
        children: [
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
