import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// The rounded panel used on the Messages / Demandes pages.
///
/// LAYER STRUCTURE: the mesh fond sits at the back; this panel is the middle
/// layer — the SOLID site black (#0E0E0E), NOT a translucent glass — with the
/// rows on top. Rounded corners (radius 28 = GlassNavBar.hugRadius) so the nav's
/// concave notches hug its bottom corners (Discover-style).
class ListPanel extends StatelessWidget {
  const ListPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E0E),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: SC.glassBorder, width: 1),
      ),
      child: child,
    );
  }
}
