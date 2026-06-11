import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';
import 'glass.dart';

/// The rounded glass panel used on the Messages / Demandes pages.
///
/// LAYER STRUCTURE: the mesh fond sits at the back; this panel is the middle
/// layer (the app's dark "Apple-glass" surface — NOT white); the page's rows
/// are laid on top. It fills the content zone and rests FLUSH on the nav bar's
/// body top, so the nav's concave notches hug its rounded bottom corners (like
/// the Discover deck). Corner radius 28 must match GlassNavBar.hugRadius.
class ListPanel extends StatelessWidget {
  const ListPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      borderRadius: BorderRadius.circular(28),
      padding: const EdgeInsets.all(6),
      // Dark frosted fill (the site's navy) so the panel reads as the dark
      // "site black" over the mesh fond — not a faint white glass.
      color: SC.bg.withValues(alpha: 0.62),
      child: child,
    );
  }
}
