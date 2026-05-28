import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Swayco "Midnight" palette — deep navy mesh background, glass
/// surfaces, cyan accent. Source of truth for every theme-aware
/// surface in the app since the legacy WhatsApp-green palette was
/// retired.
abstract final class SC {
  // Backgrounds
  static const bg            = Color(0xFF0A1024);
  static const bgDeep        = Color(0xFF050817);

  // Mesh halo colors (used by MeshBackground).
  static const meshBlue      = Color(0xFF3B82F6);
  static const meshViolet    = Color(0xFF7C3AED);
  static const meshCyan      = Color(0xFF06B6D4);
  static const meshNavy      = Color(0xFF1E40AF);

  // Accent
  static const accent        = Color(0xFF22D3EE);
  static const accentDeep    = Color(0xFF0891B2);

  // "Online" indicator — light green, used for presence dots / labels and
  // the auto-translate toggle in the chat composer.
  static const online        = Color(0xFF4ADE80);
  static const onlineDeep    = Color(0xFF22C55E);

  // Text
  static const textPrimary   = Color(0xFFF5F7FF);
  static const textSecondary = Color(0xB3F5F7FF);
  static const textMuted     = Color(0x80F5F7FF);

  // Bubble (incoming) — opaque, no blur, for legibility against the mesh.
  static const bubbleIn      = Color(0xFF1A2138);
  static const bubbleInBorder = Color(0x14FFFFFF);

  // Glass surfaces
  static const glass         = Color(0x0FFFFFFF);
  static const glassStrong   = Color(0x1AFFFFFF);
  static const glassBorder   = Color(0x1AFFFFFF);
  static const glassBorderStrong = Color(0x33FFFFFF);

  // Outgoing bubble gradient stops.
  static const outBubbleStart = Color(0xFF0891B2);
  static const outBubbleEnd   = Color(0xFF0E7490);

  /// Global Material 3 theme used by [MaterialApp.theme]. Mirrors the
  /// Midnight palette so any widget that opts into the inherited
  /// theme (default FilledButton, InputDecoration, AppBar, etc.) lands
  /// on cyan + navy instead of the old WhatsApp green + black.
  static ThemeData material() {
    const base = ColorScheme.dark(
      primary: accent,
      onPrimary: Colors.white,
      surface: bubbleIn,
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
        fillColor: bubbleIn,
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
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          padding:
              const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
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
    fontSize: 32, fontWeight: FontWeight.w800,
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
