import 'package:flutter/material.dart';

/// Pays disponibles pour le contour drapeau (design « 2a »).
enum FlagCountry {
  portugal,
  france,
  japan,
  italy,
  brazil,
  spain,
  southKorea,
  unitedStates,
  unitedKingdom,
  belgium,
  germany,
  netherlands,
  russia,
  china,
  arabic,
}

/// Définition d'un contour : le dégradé (couleurs + arrêts) et la lueur.
class FlagGradient {
  /// Couleurs du dégradé, de l'angle haut-gauche vers le bas-droit.
  final List<Color> colors;

  /// Positions (0..1) de chaque couleur. Doit avoir la même longueur que [colors].
  final List<double> stops;

  /// Couleur de la lueur (glow) diffusée autour du contour.
  final Color glow;

  const FlagGradient({
    required this.colors,
    required this.stops,
    required this.glow,
  });
}

/// Contours pré-définis pour chaque pays, calqués sur le design « 2a ».
/// Le dégradé reprend les couleurs vives du drapeau ; la lueur reprend
/// la couleur dominante à ~22 % d'opacité (0x38).
const Map<FlagCountry, FlagGradient> kFlagGradients = {
  FlagCountry.portugal: FlagGradient(
    colors: [Color(0xFF00B84F), Color(0xFF1F9D5C), Color(0xFFE8C25A), Color(0xFFFF2338)],
    stops: [0.0, 0.30, 0.55, 1.0],
    glow: Color(0x3800B84F),
  ),
  FlagCountry.france: FlagGradient(
    colors: [Color(0xFF0B40B5), Color(0xFF1F5FE0), Color(0xFFFFFFFF), Color(0xFFF11B34)],
    stops: [0.0, 0.30, 0.55, 1.0],
    glow: Color(0x381F5FE0),
  ),
  FlagCountry.japan: FlagGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFFFFDFE4), Color(0xFFFF5670), Color(0xFFE5001F)],
    stops: [0.0, 0.40, 0.70, 1.0],
    glow: Color(0x38E5001F),
  ),
  FlagCountry.italy: FlagGradient(
    colors: [Color(0xFF009246), Color(0xFF3FCE7C), Color(0xFFFFFFFF), Color(0xFFCE2B37)],
    stops: [0.0, 0.30, 0.55, 1.0],
    glow: Color(0x38009246),
  ),
  FlagCountry.brazil: FlagGradient(
    colors: [Color(0xFF009C3B), Color(0xFFFFDF00), Color(0xFF3B5BD0), Color(0xFF002776)],
    stops: [0.0, 0.45, 0.75, 1.0],
    glow: Color(0x38009C3B),
  ),
  FlagCountry.spain: FlagGradient(
    colors: [Color(0xFFAA151B), Color(0xFFF1BF00), Color(0xFFE8A900), Color(0xFFAA151B)],
    stops: [0.0, 0.50, 0.70, 1.0],
    glow: Color(0x38F1BF00),
  ),
  FlagCountry.southKorea: FlagGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFFA9C7FF), Color(0xFF0047A0), Color(0xFFCD2E3A)],
    stops: [0.0, 0.40, 0.70, 1.0],
    glow: Color(0x38CD2E3A),
  ),
  FlagCountry.unitedStates: FlagGradient(
    colors: [Color(0xFF0A3161), Color(0xFF3A5BA0), Color(0xFFFFFFFF), Color(0xFFB31942)],
    stops: [0.0, 0.30, 0.55, 1.0],
    glow: Color(0x38B31942),
  ),
  FlagCountry.unitedKingdom: FlagGradient(
    colors: [Color(0xFF012169), Color(0xFF2A4B9B), Color(0xFFFFFFFF), Color(0xFFC8102E)],
    stops: [0.0, 0.30, 0.55, 1.0],
    glow: Color(0x38012169),
  ),
  FlagCountry.belgium: FlagGradient(
    colors: [Color(0xFF1A1A1A), Color(0xFFFDDA24), Color(0xFFF3C300), Color(0xFFEF3340)],
    stops: [0.0, 0.40, 0.65, 1.0],
    glow: Color(0x38FDDA24),
  ),
  FlagCountry.germany: FlagGradient(
    colors: [Color(0xFF1A1A1A), Color(0xFFDD0000), Color(0xFFFFCE00), Color(0xFF1A1A1A)],
    stops: [0.0, 0.35, 0.65, 1.0],
    glow: Color(0x38FFCE00),
  ),
  FlagCountry.netherlands: FlagGradient(
    colors: [Color(0xFFAE1C28), Color(0xFFFFFFFF), Color(0xFF21468B), Color(0xFFAE1C28)],
    stops: [0.0, 0.40, 0.70, 1.0],
    glow: Color(0x3821468B),
  ),
  FlagCountry.russia: FlagGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFF0039A6), Color(0xFFD52B1E), Color(0xFFFFFFFF)],
    stops: [0.0, 0.35, 0.70, 1.0],
    glow: Color(0x380039A6),
  ),
  FlagCountry.china: FlagGradient(
    colors: [Color(0xFFDE2910), Color(0xFFB01E0D), Color(0xFFFFDE00), Color(0xFFDE2910)],
    stops: [0.0, 0.30, 0.55, 1.0],
    glow: Color(0x38FFDE00),
  ),
  // Pas de drapeau arabe unique (langue parlée dans ~20 pays) — palette
  // panarabe (vert/blanc/noir/rouge) plutôt qu'un pays en particulier.
  FlagCountry.arabic: FlagGradient(
    colors: [Color(0xFF1A1A1A), Color(0xFF006C35), Color(0xFFFFFFFF), Color(0xFFCE1126)],
    stops: [0.0, 0.35, 0.65, 1.0],
    glow: Color(0x38006C35),
  ),
};

/// BCP-47 primary subtag → contour drapeau. Aligné sur les 12 langues de
/// `supportedLanguages` (lib/services/languages.dart) ; `en` prend le
/// Royaume-Uni pour rester cohérent avec l'emoji 🇬🇧 déjà utilisé ailleurs
/// dans l'app pour cette langue.
const Map<String, FlagCountry> kFlagCountryForLanguage = {
  'fr': FlagCountry.france,
  'en': FlagCountry.unitedKingdom,
  'es': FlagCountry.spain,
  'de': FlagCountry.germany,
  'it': FlagCountry.italy,
  'pt': FlagCountry.portugal,
  'nl': FlagCountry.netherlands,
  'ar': FlagCountry.arabic,
  'ru': FlagCountry.russia,
  'zh': FlagCountry.china,
  'ja': FlagCountry.japan,
  'ko': FlagCountry.southKorea,
};

/// Résout le contour drapeau pour une langue (BCP-47, ex. `fr`, `fr-FR`),
/// ou `null` si la langue est vide / non reconnue.
FlagCountry? flagCountryForLanguage(String langCode) {
  final primary = langCode.trim().toLowerCase().split(RegExp(r'[-_]')).first;
  if (primary.isEmpty) return null;
  return kFlagCountryForLanguage[primary];
}

/// Contour drapeau from a profile's country name, falling back to language.
FlagCountry? flagCountryForProfile({
  required String country,
  required String language,
}) {
  const byName = <String, FlagCountry>{
    'France': FlagCountry.france,
    'Portugal': FlagCountry.portugal,
    'Japon': FlagCountry.japan,
    'Japan': FlagCountry.japan,
    'Italie': FlagCountry.italy,
    'Italy': FlagCountry.italy,
    'Brésil': FlagCountry.brazil,
    'Brazil': FlagCountry.brazil,
    'Espagne': FlagCountry.spain,
    'Spain': FlagCountry.spain,
    'Corée du Sud': FlagCountry.southKorea,
    'South Korea': FlagCountry.southKorea,
    'États-Unis': FlagCountry.unitedStates,
    'United States': FlagCountry.unitedStates,
    'USA': FlagCountry.unitedStates,
    'Royaume-Uni': FlagCountry.unitedKingdom,
    'United Kingdom': FlagCountry.unitedKingdom,
    'UK': FlagCountry.unitedKingdom,
    'Belgique': FlagCountry.belgium,
    'Belgium': FlagCountry.belgium,
    'Allemagne': FlagCountry.germany,
    'Germany': FlagCountry.germany,
    'Pays-Bas': FlagCountry.netherlands,
    'Netherlands': FlagCountry.netherlands,
    'Russie': FlagCountry.russia,
    'Russia': FlagCountry.russia,
    'Chine': FlagCountry.china,
    'China': FlagCountry.china,
  };
  final named = byName[country.trim()];
  if (named != null) return named;
  return flagCountryForLanguage(language);
}
