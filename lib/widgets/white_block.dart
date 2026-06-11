import 'package:flutter/material.dart';

/// The white rounded panel used on the Messages / Demandes pages.
///
/// LAYER STRUCTURE: the mesh fond sits at the back; this white block is the
/// middle layer; the page's rows are laid on top as sections. It is sized to
/// its content and lives INSIDE the page's scroll view, so the whole panel
/// moves up/down as you scroll (it is not a fixed pane with an inner scroll).
/// Full-width, rounded on all four corners like the Discover deck.
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
