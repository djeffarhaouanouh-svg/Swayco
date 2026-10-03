import 'package:flutter/material.dart';

import '../theme/swayco_palette.dart';

/// Fond de marque des pages (Réglages…) : couleur pleine + halo bleu/cyan en
/// haut — blanc en clair, #0A0F1C en sombre (variante 18d).
class MeshBackground extends StatelessWidget {
  const MeshBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SwaycoBackground(child: child);
}
