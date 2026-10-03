import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'swayco_palette.dart';

/// Swayco — direction 8c.
/// Fond #0E0E0E, GlassNavBar et polices (bricolageGrotesque / dmSans)
/// inchangés. Nouveau : dégradé de l'icône (bleu franc → bleu → cyan,
/// sans indigo), accent jaune 8c #F4FF1F. La police Plus Jakarta Sans de
/// la 8c est réservée aux sous-titres de l'onboarding ([SwayOnb.body]).
/// Tous les anciens noms sont conservés : rien d'autre à renommer dans l'app.
abstract final class SC {
  /// Vrai en mode clair (« halo de marque »). Posé par [apply] depuis
  /// `MaterialApp.builder` avant que l'arbre ne se construise : les couleurs
  /// de fond / texte / surfaces ci-dessous suivent donc le thème actif.
  static bool light = false;

  /// Apparence « Noir » : l'ancien fond #0E0E0E, sans halo.
  static bool classic = false;

  /// Règle les couleurs « fond / texte / surfaces » sur le thème en cours.
  static bool? _lastLight;
  static bool? _lastClassic;

  /// Règle les couleurs sur le thème actif. Renvoie VRAI quand l'apparence a
  /// CHANGÉ depuis le dernier appel (hors tout premier appel) : les écrans déjà
  /// construits ne lisent SC.* qu'à leur construction — il faut alors les
  /// reconstruire tous (voir AppTheme.rebuildAll).
  static bool apply(Brightness b, {bool classicBlack = false}) {
    light = b == Brightness.light;
    classic = classicBlack && !light;
    final changed =
        _lastLight != null && (_lastLight != light || _lastClassic != classic);
    _lastLight = light;
    _lastClassic = classic;
    return changed;
  }

  // Valeurs SOMBRES figées : pour les écrans qui restent sombres (ou sur
  // dégradé bleu) quel que soit le thème — appel, onboarding, connexion,
  // recadrage photo, match. À la place de `SC.textPrimary` & co.
  static const dBg = Color(0xFF0A0F1C);
  static const dTextPrimary = Color(0xFFF5F7FF);
  static const dTextSecondary = Color(0xB3F5F7FF);
  static const dTextMuted = Color(0x80F5F7FF);
  static const dMenu = Color(0xFF161D30);
  static const dBubbleIn = Color(0xFF1A2138);
  static const dBubbleInBorder = Color(0x14FFFFFF);
  static const dGlass = Color(0x0FFFFFFF);
  static const dGlassStrong = Color(0x1AFFFFFF);
  static const dGlassBorder = Color(0x1AFFFFFF);
  static const dGlassBorderStrong = Color(0x33FFFFFF);
  static const dMsgInBg = Color(0xFF2F333B);
  static const dMsgInText = Color(0xFFF5F7FF);
  static const dMsgInBorder = Color(0x1FFFFFFF);
  /// Fond des écrans-ONGLETS (Messages, Découvrir, Likes, Profil) : transparent
  /// en mode clair — le fond blanc + halo est posé une seule fois par le shell
  /// ([SwaycoBackground]), pour que le halo ne se double pas. Identique à [bg]
  /// en sombre. Les pages poussées gardent [bg] (opaque).
  static Color get tabBg => Colors.transparent;

  // Backgrounds (inchangés en sombre)
  static Color get bg => light
      ? const Color(0xFFFFFFFF)
      : (classic ? const Color(0xFF0E0E0E) : const Color(0xFF0A0F1C));
  /// Encre posée SUR l'accent jaune (texte des badges / boutons pleins).
  static const bgDeep        = Color(0xFF04123A);

  // Dégradé de marque — celui de l'icône, indigo retiré.
  static const brandBlueDeep = Color(0xFF1F5EFF);
  static const brandBlue     = Color(0xFF2B7FFF);
  static const brandCyan     = Color(0xFF18DDEA);
  static const brandGradient = LinearGradient(
    begin: Alignment(-0.6, -1),
    end: Alignment(0.6, 1),
    colors: [brandBlueDeep, brandBlue, brandCyan],
    stops: [0, .52, 1],
  );

  // Mesh halo colors (MeshBackground) — le violet devient le bleu franc.
  static const meshBlue      = brandBlue;
  static const meshViolet    = brandBlueDeep;
  static const meshCyan      = brandCyan;
  static const meshNavy      = Color(0xFF1A4FD6);

  // ── Aides du mode clair 17d : un blanc posé sur le FOND devient de l'encre.
  /// Texte / icône posé sur le fond de l'écran (pas sur photo, dégradé ou jaune).
  static Color get fg => light ? const Color(0xFF04123A) : Colors.white;

  /// Équivalent de Colors.white.withValues(alpha: a) sur le fond.
  static Color fgA(double a) => light
      ? const Color(0xFF04123A).withValues(alpha: (a * 1.1).clamp(0.0, 1.0))
      : Colors.white.withValues(alpha: a);

  /// Remplissage « verre » (blanc 6–18 %) sur le fond : surface #F2F6FF en clair.
  static Color get fill =>
      light ? const Color(0xFFF2F6FF) : Colors.white.withValues(alpha: 0.10);

  /// Bord fin (blanc 12–35 %) sur le fond.
  static Color get stroke =>
      light ? const Color(0x261F5EFF) : Colors.white.withValues(alpha: 0.18);

  /// Ombre des éléments blancs en clair (sinon blanc sur blanc).
  static List<BoxShadow> get lift => light
      ? const [
          BoxShadow(
            color: Color(0x2E1F5EFF),
            blurRadius: 18,
            spreadRadius: -8,
            offset: Offset(0, 6),
          ),
        ]
      : const [];

  // Accent — jaune 8c.
  static const accent        = Color(0xFFF4FF1F);
  static const accentDeep    = Color(0xFFC8D100);
  /// [accent] à peine éclairci (15 % vers le blanc) : petites pastilles
  /// posées sur une photo, où le jaune plein paraît trop lourd.
  static const accentSoft    = Color(0xFFF6FF41);
  /// Le jaune comme TEXTE / ICÔNE / contour : en mode clair le jaune est
  /// illisible sur blanc, on prend le bleu de marque. En sombre = [accent].
  /// (Le jaune reste un FOND, avec du texte [onAccent].)
  static Color get accentFg => light ? brandBlueDeep : accent;

  /// Texte / icône posé sur [accent]. Jamais de blanc sur le jaune.
  static const onAccent      = bgDeep;

  static const brandFont     = 'GlacialIndifference';

  // Online (inchangé)
  static const online        = Color(0xFF4ADE80);
  static const onlineDeep    = Color(0xFF22C55E);

  // Text (inchangé)
  static Color get textPrimary =>
      light ? const Color(0xFF04123A) : const Color(0xFFF5F7FF);
  static Color get textSecondary =>
      light ? const Color(0xFF5A6890) : const Color(0xB3F5F7FF);
  static Color get textMuted =>
      light ? const Color(0xFF8A94B0) : const Color(0x80F5F7FF);

  static Color get menu =>
      light
          ? const Color(0xFFF2F6FF)
          : (classic ? const Color(0xFF2B2B2B) : const Color(0xFF161D30));

  static Color get bubbleIn =>
      light ? const Color(0xFFF2F6FF) : const Color(0xFF1A2138);
  static Color get bubbleInBorder =>
      light ? const Color(0x1A1F5EFF) : const Color(0x14FFFFFF);

  // Glass
  static Color get glass =>
      light ? const Color(0x0A04123A) : const Color(0x0FFFFFFF);
  static Color get glassStrong =>
      light ? const Color(0x0F04123A) : const Color(0x1AFFFFFF);
  static Color get glassBorder =>
      light ? const Color(0x1A1F5EFF) : const Color(0x1AFFFFFF);
  static Color get glassBorderStrong =>
      light ? const Color(0x331F5EFF) : const Color(0x33FFFFFF);

  // Bulle sortante : bleu de marque au lieu du cyan foncé.
  static const outBubbleStart = brandBlueDeep;
  static const outBubbleEnd   = brandBlue;

  static Color get msgInBg =>
      light ? const Color(0xFFF2F6FF) : const Color(0xFF2F333B);
  static Color get msgInText =>
      light ? const Color(0xFF04123A) : const Color(0xFFF5F7FF);
  static Color get msgInBorder =>
      light ? const Color(0x1A1F5EFF) : const Color(0x1FFFFFFF);
  static const msgOutBg      = Color(0xFF123C9E);
  static const msgOutBorder  = brandBlue;
  static const msgOutText    = Color(0xFFFFFFFF);

  static ThemeData material({bool classicBlack = false}) {
    final dBg = classicBlack ? const Color(0xFF0E0E0E) : const Color(0xFF0A0F1C);
    const dText = Color(0xFFF5F7FF);
    final dMenu =
        classicBlack ? const Color(0xFF2B2B2B) : const Color(0xFF161D30);
    const dBorder = Color(0x1AFFFFFF);
    final base = ColorScheme.dark(
      primary: accent,
      onPrimary: onAccent,
      secondary: brandBlue,
      onSecondary: Colors.white,
      surface: dMenu,
      onSurface: dText,
      error: Color(0xFFE53935),
      onError: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: base,
      scaffoldBackgroundColor: dBg,
      extensions: [classicBlack ? classicPalette : SwaycoPalette.dark],
      appBarTheme: AppBarTheme(
        backgroundColor: dBg,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: dText,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dMenu,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: dBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: Color(0x80F5F7FF)),
        labelStyle: const TextStyle(color: Color(0x80F5F7FF)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: const StadiumBorder(),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.35),
        selectionHandleColor: accent,
      ),
      dividerTheme: const DividerThemeData(color: dBorder),
    );
  }

  /// Palette de l'apparence « Noir » : l'ancien fond #0E0E0E, sans halo.
  static const classicPalette = SwaycoPalette(
    bg: Color(0xFF0E0E0E),
    halo: null,
    surface: Color(0xFF1F1F22),
    card: Color(0x0FFFFFFF),
    line: Color(0x1AFFFFFF),
    ink: Color(0xFFF5F7FF),
    inkSecondary: Color(0x99F5F7FF),
    inkMuted: Color(0x80FFFFFF),
    navGlass: Color(0x21FFFFFF),
    navBorder: Color(0x38FFFFFF),
    navActive: Color(0x2EFFFFFF),
    cardShadow: [],
    statusBar: Brightness.light,
  );

  /// Mode clair « halo de marque » : fond blanc, encre #04123A. Le Scaffold
  /// reste opaque (blanc) ; le halo est posé par [SwaycoBackground] sur les
  /// écrans principaux.
  static ThemeData lightMaterial() {
    const ink = Color(0xFF04123A);
    const surface = Color(0xFFF2F6FF);
    const line = Color(0x1A1F5EFF);
    const base = ColorScheme.light(
      primary: brandBlueDeep,
      onPrimary: Colors.white,
      secondary: brandBlue,
      onSecondary: Colors.white,
      surface: Color(0xFFFFFFFF),
      onSurface: ink,
      error: Color(0xFFE53935),
      onError: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: base,
      scaffoldBackgroundColor: const Color(0xFFFFFFFF),
      extensions: const [SwaycoPalette.light],
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFFFFF),
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: brandBlueDeep, width: 1.5),
        ),
        hintStyle: const TextStyle(color: Color(0xFF8A94B0)),
        labelStyle: const TextStyle(color: Color(0xFF8A94B0)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: const StadiumBorder(),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: brandBlueDeep,
        selectionColor: brandBlue.withValues(alpha: 0.3),
        selectionHandleColor: brandBlueDeep,
      ),
      dividerTheme: const DividerThemeData(color: line),
    );
  }
}
abstract final class SCText {
  static TextStyle get h1 => GoogleFonts.bricolageGrotesque(
    fontSize: 30, fontWeight: FontWeight.w800,
    letterSpacing: -1.0, color: SC.textPrimary, height: 1.05,
  );
  static TextStyle get h2 => GoogleFonts.bricolageGrotesque(
    fontSize: 22, fontWeight: FontWeight.w700,
    letterSpacing: -0.4, color: SC.textPrimary,
  );
  static TextStyle get h3 => GoogleFonts.bricolageGrotesque(
    fontSize: 18, fontWeight: FontWeight.w700,
    letterSpacing: -0.2, color: SC.textPrimary,
  );
  /// Body copy of the pop-ups (and other multi-line helper text).
  static TextStyle get subtitle => GoogleFonts.dmSans(
    fontSize: 15, fontWeight: FontWeight.w500,
    color: SC.textPrimary, height: 1.45,
  );
  static TextStyle get name => GoogleFonts.dmSans(
    fontSize: 16, fontWeight: FontWeight.w700, color: SC.textPrimary,
  );
  static TextStyle get body => GoogleFonts.dmSans(
    fontSize: 15, fontWeight: FontWeight.w500, color: SC.textPrimary, height: 1.3,
  );
  static TextStyle get preview => GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w400, color: SC.textMuted,
  );
  static TextStyle get meta => GoogleFonts.dmSans(
    fontSize: 11, fontWeight: FontWeight.w600, color: SC.textMuted,
  );
  static TextStyle get accent => GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w700, color: SC.accentFg,
  );
}
