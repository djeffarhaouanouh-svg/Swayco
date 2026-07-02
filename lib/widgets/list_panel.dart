import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// The rounded panel used on the Messages / Demandes pages.
class ListPanel extends StatelessWidget {
  const ListPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        // The original site black.
        color: const Color(0xFF0E0E0E),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: SC.glassBorder, width: 1),
        // Cyan-blue halo around the panel — the Discover card's glow.
        boxShadow: [
          BoxShadow(
            color: SC.meshCyan.withValues(alpha: 0.45),
            blurRadius: 44,
            spreadRadius: -6,
          ),
          BoxShadow(
            color: SC.meshBlue.withValues(alpha: 0.30),
            blurRadius: 90,
            spreadRadius: 2,
          ),
        ],
      ),
      child: child,
    );
  }
}
