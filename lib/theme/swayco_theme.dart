import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Swayco "Midnight" palette — deep navy mesh background, glass surfaces,
/// cyan accent. Use alongside [WhatsAppCallTheme] in screens that have
/// been restyled (Messages / Discover / Chat thread); other screens keep
/// the legacy WhatsApp-green palette until they're migrated too.
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
