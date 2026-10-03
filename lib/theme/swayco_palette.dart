import 'package:flutter/material.dart';

/// Swayco — fond 18d « noir + halo de marque ». Seule la palette `dark` est utilisée
/// (l'app reste en mode sombre). `light` est gardée pour un futur mode clair.
/// À utiliser à la place des couleurs « fond / texte / surfaces » de `SC`
/// (`SC.bg`, `SC.textPrimary`, `SC.menu`, `SC.glass…`). Les couleurs de marque
/// (`SC.accent` #F4FF1F, `SC.brandGradient`, `SC.brandBlue`…) ne changent pas.
@immutable
class SwaycoPalette extends ThemeExtension<SwaycoPalette> {
  const SwaycoPalette({
    required this.bg,
    required this.halo,
    required this.surface,
    required this.card,
    required this.line,
    required this.ink,
    required this.inkSecondary,
    required this.inkMuted,
    required this.navGlass,
    required this.navBorder,
    required this.navActive,
    required this.cardShadow,
    required this.statusBar,
  });

  /// Fond plein des écrans.
  final Color bg;
  /// Halo de marque posé en haut du fond (null = pas de halo).
  final Gradient? halo;
  /// Ronds, champs, cases vides (pays, boutons ✕ / ♥, photos vides).
  final Color surface;
  /// Cartes (liste de conversations, panneaux).
  final Color card;
  /// Bords fins et séparateurs.
  final Color line;
  /// Texte principal.
  final Color ink;
  /// Texte secondaire (aperçus, heures, @pseudo).
  final Color inkSecondary;
  /// Icônes et libellés inactifs (nav).
  final Color inkMuted;
  /// Fond de la GlassNavBar.
  final Color navGlass;
  final Color navBorder;
  /// Pastille de l'onglet actif dans la nav.
  final Color navActive;
  final List<BoxShadow> cardShadow;
  final Brightness statusBar;

  /// Mode clair 17d « Blanc + halo de marque ».
  static const light = SwaycoPalette(
    bg: Color(0xFFFFFFFF),
    halo: RadialGradient(
      center: Alignment(0, -1),
      radius: 1.2,
      colors: [Color(0x332B7FFF), Color(0x1A18DDEA), Color(0x00FFFFFF)],
      stops: [0, .4, .75],
    ),
    surface: Color(0xFFF2F6FF),
    card: Color(0xFFFFFFFF),
    line: Color(0x1A1F5EFF),
    ink: Color(0xFF04123A),
    inkSecondary: Color(0xFF5A6890),
    inkMuted: Color(0xFF8A94B0),
    navGlass: Color(0xB8FFFFFF),
    navBorder: Color(0x1A04123A),
    navActive: Color(0x1A1F5EFF),
    cardShadow: [BoxShadow(color: Color(0x401F5EFF), blurRadius: 28, spreadRadius: -12, offset: Offset(0, 10))],
    statusBar: Brightness.dark,
  );

  /// Mode sombre « noir + halo de marque » (maquette 18d), pendant de 17d.
  static const dark = SwaycoPalette(
    bg: Color(0xFF0A0F1C),
    halo: RadialGradient(
      center: Alignment(0, -1),
      radius: 1.2,
      colors: [Color(0x611F5EFF), Color(0x1F18DDEA), Color(0x000A0F1C)],
      stops: [0, .4, .75],
    ),
    surface: Color(0xFF161D30),
    card: Color(0x0FFFFFFF),
    line: Color(0x1AFFFFFF),
    ink: Color(0xFFF5F7FF),
    inkSecondary: Color(0x9EF5F7FF),
    inkMuted: Color(0x80FFFFFF),
    navGlass: Color(0x21FFFFFF),
    navBorder: Color(0x38FFFFFF),
    navActive: Color(0x2EFFFFFF),
    cardShadow: [BoxShadow(color: Color(0x99000000), blurRadius: 28, spreadRadius: -12, offset: Offset(0, 10))],
    statusBar: Brightness.light,
  );

  static SwaycoPalette of(BuildContext context) =>
      Theme.of(context).extension<SwaycoPalette>() ?? dark;

  @override
  SwaycoPalette copyWith() => this;

  @override
  SwaycoPalette lerp(ThemeExtension<SwaycoPalette>? other, double t) =>
      t < .5 ? this : (other as SwaycoPalette? ?? this);
}

/// Fond d'écran Swayco : couleur pleine + halo de marque (clair ET sombre).
/// Remplace `backgroundColor: SC.bg` : mets le Scaffold en
/// `backgroundColor: Colors.transparent` et enveloppe-le dans ce widget.
class SwaycoBackground extends StatelessWidget {
  const SwaycoBackground({super.key, required this.child, this.haloHeight = 380});

  final Widget child;
  /// Hauteur du halo depuis le haut de l'écran (380 ≈ maquette 17d).
  final double haloHeight;

  @override
  Widget build(BuildContext context) {
    final p = SwaycoPalette.of(context);
    return ColoredBox(
      color: p.bg,
      child: Stack(
        children: [
          // Toujours DEUX enfants, halo ou pas : si la couche du halo disparaissait
          // (mode Noir, clair 17b), l'écran glisserait à sa place dans la Stack et
          // Flutter le reconstruirait de zéro — tout l'état perdu, et un écran
          // gris (erreur) au changement d'apparence.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: haloHeight,
            child: IgnorePointer(
              child: p.halo == null
                  ? const SizedBox.shrink()
                  : DecoratedBox(decoration: BoxDecoration(gradient: p.halo)),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}
