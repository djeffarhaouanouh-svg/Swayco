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
        // Soft neutral drop shadow — classic black look, no blue glow.
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 32,
            spreadRadius: -8,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}
