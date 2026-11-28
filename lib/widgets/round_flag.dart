import 'package:flutter/material.dart';

import '../services/languages.dart';
import '../services/locations.dart';

/// Drapeau rond d'un pays (flagcdn) ; à défaut l'emoji du pays, ou celui de la
/// langue parlée.
class RoundFlag extends StatelessWidget {
  const RoundFlag({
    super.key,
    required this.country,
    this.language = '',
    this.size = 18,
    this.ring = false,
  });

  final String country;
  final String language;
  final double size;

  /// Liseré blanc (le drapeau posé sur une photo de profil).
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final iso = countryIso2For(country);
    final emoji = countryFlagFor(country) ??
        findLanguageByCode(language)?.flag ??
        '';
    if (iso.isEmpty && emoji.isEmpty) return const SizedBox.shrink();
    final fallback = FittedBox(
      fit: BoxFit.cover,
      child: Text(emoji, style: const TextStyle(fontSize: 20, height: 1)),
    );
    return Container(
      width: size,
      height: size,
      foregroundDecoration: ring
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            )
          : null,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(shape: BoxShape.circle),
      child: iso.isEmpty
          ? fallback
          : Image.network(
              'https://flagcdn.com/w80/${iso.toLowerCase()}.png',
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
