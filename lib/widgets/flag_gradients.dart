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

/// The two dominant flag colours used for the round photo ring on the match
/// card. Keyed by the stored French country label; falls back to the
/// language-based gradient, then to the cyan house pair.
List<Color> flagRingColors({required String country, required String language}) {
  const byCountry = <String, List<Color>>{
    'France': [Color(0xFF0B40B5), Color(0xFFF11B34)],
    'Belgique': [Color(0xFF2D2926), Color(0xFFEF3340)],
    'Suisse': [Color(0xFFD52B1E), Color(0xFFD52B1E)],
    'Canada': [Color(0xFFD80621), Color(0xFFD80621)],
    'États-Unis': [Color(0xFF0A3161), Color(0xFFB31942)],
    'Royaume-Uni': [Color(0xFF012169), Color(0xFFC8102E)],
    'Espagne': [Color(0xFFAA151B), Color(0xFFF1BF00)],
    'Portugal': [Color(0xFF00B84F), Color(0xFFFF2338)],
    'Italie': [Color(0xFF009246), Color(0xFFCE2B37)],
    'Allemagne': [Color(0xFF1A1A1A), Color(0xFFFFCE00)],
    'Pays-Bas': [Color(0xFFAE1C28), Color(0xFF21468B)],
    'Mexique': [Color(0xFF006847), Color(0xFFCE1126)],
    'Argentine': [Color(0xFF74ACDF), Color(0xFFF6B40E)],
    'Colombie': [Color(0xFFFCD116), Color(0xFFCE1126)],
    'Brésil': [Color(0xFF009C3B), Color(0xFF002776)],
    'Maroc': [Color(0xFFC1272D), Color(0xFF006233)],
    'Algérie': [Color(0xFF006233), Color(0xFFD21034)],
    'Tunisie': [Color(0xFFE70013), Color(0xFFE70013)],
    'Sénégal': [Color(0xFF00853F), Color(0xFFE31B23)],
    "Côte d'Ivoire": [Color(0xFFF77F00), Color(0xFF009E60)],
    'Égypte': [Color(0xFFCE1126), Color(0xFF1A1A1A)],
    'Arabie Saoudite': [Color(0xFF006C35), Color(0xFF006C35)],
    'Émirats arabes unis': [Color(0xFF00732F), Color(0xFFFF0000)],
    'Turquie': [Color(0xFFE30A17), Color(0xFFE30A17)],
    'Russie': [Color(0xFF0039A6), Color(0xFFD52B1E)],
    'Chine': [Color(0xFFDE2910), Color(0xFFFFDE00)],
    'Japon': [Color(0xFFE5001F), Color(0xFFE5001F)],
    'Corée du Sud': [Color(0xFF0047A0), Color(0xFFCD2E3A)],
    'Inde': [Color(0xFFFF9933), Color(0xFF138808)],
    'Australie': [Color(0xFF00247D), Color(0xFFCF142B)],
    'Luxembourg': [Color(0xFFED2939), Color(0xFF00A1DE)],
    'Islande': [Color(0xFF02529C), Color(0xFFDC1E35)],
    'Norvège': [Color(0xFFBA0C2F), Color(0xFF00205B)],
    'Suède': [Color(0xFF006AA7), Color(0xFFFECC00)],
    'Danemark': [Color(0xFFC8102E), Color(0xFFC8102E)],
    'Finlande': [Color(0xFF003580), Color(0xFF003580)],
    'Irlande': [Color(0xFF169B62), Color(0xFFFF883E)],
    'Pologne': [Color(0xFFDC143C), Color(0xFFDC143C)],
    'Ukraine': [Color(0xFF0057B7), Color(0xFFFFDD00)],
    'Grèce': [Color(0xFF0D5EAF), Color(0xFF0D5EAF)],
  };
  final named = byCountry[country.trim()];
  if (named != null) return named;
  final byLang = flagCountryForLanguage(language);
  if (byLang != null) {
    final g = kFlagGradients[byLang]!;
    return [g.colors.first, g.colors.last];
  }
  return const [Color(0xFF22D3EE), Color(0xFFA78BFA)];
}

