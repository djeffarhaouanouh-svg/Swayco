import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Midnight ambient background — four radial halos (blue / violet / cyan
/// / deep navy) stacked over a navy base, plus a soft vignette for text
/// legibility. Drop it just inside [Scaffold.body] when the scaffold's
/// own background is transparent.
class MeshBackground extends StatelessWidget {
  const MeshBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SC.bg,
      child: Stack(
        children: [
          _halo(alignment: const Alignment(-1, -1), color: SC.meshBlue,   radius: 0.9),
          _halo(alignment: const Alignment( 1, -1), color: SC.meshViolet, radius: 0.8),
          _halo(alignment: const Alignment( 1,  1), color: SC.meshCyan,   radius: 0.9),
          _halo(alignment: const Alignment(-1,  1), color: SC.meshNavy,   radius: 1.0),
          // Vignette: nudges contrast up at the edges without going pitch black.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.2,
                colors: [Colors.transparent, Color(0x33000000)],
              ),
            ),
            child: SizedBox.expand(),
          ),
          child,
        ],
      ),
    );
  }

  Widget _halo({
    required Alignment alignment,
    required Color color,
    required double radius,
  }) {
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: radius,
        heightFactor: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0)],
              stops: const [0.0, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
