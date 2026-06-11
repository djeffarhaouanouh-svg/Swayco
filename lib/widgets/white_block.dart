import 'package:flutter/material.dart';

/// White-theme variant of the list panel (kept for later — NOT wired in right
/// now; the live panel is the dark [ListPanel] in list_panel.dart).
///
/// Solid white rounded card with the same geometry as [ListPanel] (radius 28,
/// fills the zone, rests flush on the nav so the hug notches wrap its bottom
/// corners). Swap `ListPanel` for `WhiteBlock` in chat_screen / friend_requests
/// to flip Messages + Demandes to the white theme. When using it, also restore
/// dark text on the rows (name 0xFF263043, sub/time 0xFF8A93A6) and cyan
/// hover/highlight/splash on the InkWells (white-on-white is invisible).
class WhiteBlock extends StatelessWidget {
  const WhiteBlock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}
