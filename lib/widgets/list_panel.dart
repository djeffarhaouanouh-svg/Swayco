import 'package:flutter/material.dart';

/// The rounded panel used on the Messages / Demandes pages.
class ListPanel extends StatelessWidget {
  const ListPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(6),
      // Same dark grey as the page behind it — no border/shadow, so the
      // panel blends into the page instead of showing its own edges.
      decoration: const BoxDecoration(color: Color(0xFF0E0E0E)),
      child: child,
    );
  }
}
