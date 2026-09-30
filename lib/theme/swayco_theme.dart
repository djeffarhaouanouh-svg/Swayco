import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Swayco — direction 8c.
/// Fond #0E0E0E, GlassNavBar et polices (bricolageGrotesque / dmSans)
/// inchangés. Nouveau : dégradé de l'icône (bleu franc → bleu → cyan,
/// sans indigo), accent jaune 8c #F4FF1F. La police Plus Jakarta Sans de
/// la 8c est réservée aux sous-titres de l'onboarding ([SwayOnb.body]).
/// Tous les anciens noms sont conservés : rien d'autre à renommer dans l'app.
abstract final class SC {
  // Backgrounds (inchangés)
  static const bg            = Color(0xFF0E0E0E);
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

  // Accent — jaune 8c.
  static const accent        = Color(0xFFF4FF1F);
  static const accentDeep    = Color(0xFFC8D100);
  /// [accent] éclairci (40 % vers le blanc) : petites pastilles posées sur
  /// une photo, où le jaune plein paraît trop lourd.
  static const accentSoft    = Color(0xFFF8FF79);
  /// Texte / icône posé sur [accent]. Jamais de blanc sur le jaune.
  static const onAccent      = bgDeep;

  static const brandFont     = 'GlacialIndifference';

  // Online (inchangé)
  static const online        = Color(0xFF4ADE80);
  static const onlineDeep    = Color(0xFF22C55E);

  // Text (inchangé)
  static const textPrimary   = Color(0xFFF5F7FF);
  static const textSecondary = Color(0xB3F5F7FF);
  static const textMuted     = Color(0x80F5F7FF);

  static const menu          = Color(0xFF2B2B2B);

  static const bubbleIn      = Color(0xFF1A2138);
  static const bubbleInBorder = Color(0x14FFFFFF);

  // Glass (inchangé)
  static const glass         = Color(0x0FFFFFFF);
  static const glassStrong   = Color(0x1AFFFFFF);
  static const glassBorder   = Color(0x1AFFFFFF);
  static const glassBorderStrong = Color(0x33FFFFFF);

  // Bulle sortante : bleu de marque au lieu du cyan foncé.
  static const outBubbleStart = brandBlueDeep;
  static const outBubbleEnd   = brandBlue;

  static const msgInBg       = Color(0xFF2F333B);
  static const msgInText     = Color(0xFFF5F7FF);
  static const msgInBorder   = Color(0x1FFFFFFF);
  static const msgOutBg      = Color(0xFF123C9E);
  static const msgOutBorder  = brandBlue;
  static const msgOutText    = Color(0xFFFFFFFF);

  static ThemeData material() {
    const base = ColorScheme.dark(
      primary: accent,
      onPrimary: onAccent,
      secondary: brandBlue,
      onSecondary: Colors.white,
      surface: menu,
      onSurface: textPrimary,
      error: Color(0xFFE53935),
      onError: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: base,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: menu,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted),
        labelStyle: const TextStyle(color: textMuted),
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
      dividerTheme: const DividerThemeData(color: glassBorder),
    );
  }
}

abstract final class SCText {
  static TextStyle h1 = GoogleFonts.bricolageGrotesque(
    fontSize: 30, fontWeight: FontWeight.w800,
    letterSpacing: -1.0, color: SC.textPrimary, height: 1.05,
  );
  static TextStyle h2 = GoogleFonts.bricolageGrotesque(
    fontSize: 22, fontWeight: FontWeight.w700,
    letterSpacing: -0.4, color: SC.textPrimary,
  );
  static TextStyle h3 = GoogleFonts.bricolageGrotesque(
    fontSize: 18, fontWeight: FontWeight.w700,
    letterSpacing: -0.2, color: SC.textPrimary,
  );
  static TextStyle name = GoogleFonts.dmSans(
    fontSize: 16, fontWeight: FontWeight.w700, color: SC.textPrimary,
  );
  static TextStyle body = GoogleFonts.dmSans(
    fontSize: 15, fontWeight: FontWeight.w500, color: SC.textPrimary, height: 1.3,
  );
  static TextStyle preview = GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w400, color: SC.textMuted,
  );
  static TextStyle meta = GoogleFonts.dmSans(
    fontSize: 11, fontWeight: FontWeight.w600, color: SC.textMuted,
  );
  static TextStyle accent = GoogleFonts.dmSans(
    fontSize: 12, fontWeight: FontWeight.w700, color: SC.accent,
  );
}
