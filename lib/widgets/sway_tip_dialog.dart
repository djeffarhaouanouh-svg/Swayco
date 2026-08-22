// ─────────────────────────────────────────────────────────────────────────────
// sway_tip_dialog.dart — écrans 04 (Discover) et 05 (Profil) de la maquette
//
// Où le mettre :  lib/widgets/sway_tip_dialog.dart
// Dépend de :     lib/widgets/sway_onb_kit.dart (SwayOnb, SwayCta) — déjà livré.
// Dépendances pubspec : aucune nouvelle.
//
// ── PATCH — lib/screens/root_shell.dart ─────────────────────────────────────
// 1. ajouter :        import '../widgets/sway_tip_dialog.dart';
//
// 2. remplacer la méthode `_showTip({...})` par :
//
//      Future<void> _showTip({
//        required IconData icon,
//        required String title,
//        required String body,
//        required String buttonLabel,
//        String? imageAsset,
//        SwayTipArt art = SwayTipArt.profileRing,
//      }) {
//        return showDialog<void>(
//          context: context,
//          barrierDismissible: false,
//          barrierColor: const Color(0x99050608),
//          builder: (_) => SwayTipDialog(
//            art: art,
//            title: title,
//            body: body,
//            buttonLabel: buttonLabel,
//          ),
//        );
//      }
//
//    (`icon` et `imageAsset` restent dans la signature pour ne rien casser
//    aux 3 appels existants ; ils ne sont simplement plus utilisés. L'asset
//    assets/add-picture.png et son precacheImage deviennent inutiles —
//    supprimables dans _maybeShowProfileTip.)
//
// 3. dans `_maybeShowOnboardingTips()`, sur le PREMIER tip seulement, ajouter
//    l'argument d'illustration :
//
//      await _showTip(
//        icon: Icons.add_a_photo_rounded,
//        title: AppStrings.t('tip_photo_title'),
//        body: AppStrings.t('tip_photo_body'),
//        buttonLabel: AppStrings.t('tip_next'),
//        art: SwayTipArt.discoverTiles,          // ← écran 04
//      );
//
//    Les deux autres appels (`tip_photo_where_*` et `tip_profile_here_*`)
//    n'ont rien à changer : ils prennent SwayTipArt.profileRing par défaut,
//    qui est l'écran 05.
//
// 4. la classe privée `_TipDialog` en bas du fichier devient inutilisée :
//    supprimable.
//
// Option « Plus tard » (présente sur la maquette 04, absente de ton code
// actuel) : passer `secondaryLabel: AppStrings.t('later')` au SwayTipDialog
// et récupérer le résultat — showDialog<bool> renvoie false sur ce bouton.
// Laissée désactivée par défaut pour ne pas changer le comportement.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/swayco_theme.dart';
import 'sway_onb_kit.dart';

/// Les deux illustrations dessinées de la maquette.
enum SwayTipArt {
  /// Écran 04 — trois vignettes façon rangée Discover, celle du centre
  /// en avant avec le contour cyan et le badge « + ».
  discoverTiles,

  /// Écran 05 — l'emplacement de photo lui-même : anneau pointillé,
  /// cercle qui glow, badge « + ».
  profileRing,
}

/// Coach-mark de la direction 1e : carte noire à halos, titre display avec
/// le dernier mot surligné en cyan, CTA plein.
///
/// Pop `true` sur le bouton principal, `false` sur le lien secondaire.
class SwayTipDialog extends StatelessWidget {
  const SwayTipDialog({
    super.key,
    required this.art,
    required this.title,
    required this.body,
    required this.buttonLabel,
    this.secondaryLabel,
  });

  final SwayTipArt art;
  final String title;
  final String body;
  final String buttonLabel;
  final String? secondaryLabel;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: SwayOnb.screenBg,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: SwayOnb.fieldBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0xE6000000),
                blurRadius: 70,
                spreadRadius: -20,
                offset: Offset(0, 30),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Les mêmes halos que l'onboarding, orientés selon l'illustration.
              Positioned.fill(
                child: ClipRect(
                  child: Stack(
                    children: art == SwayTipArt.discoverTiles
                        ? const [
                            _CardHalo(SwayOnb.haloCyan, .26, 320,
                                top: -130, left: -90),
                            _CardHalo(SwayOnb.haloBlue, .22, 260,
                                top: -60, right: -110),
                            _CardHalo(SwayOnb.haloPink, .14, 270,
                                bottom: -110, left: -50),
                          ]
                        : const [
                            _CardHalo(SwayOnb.haloCyan, .26, 320,
                                top: -130, right: -90),
                            _CardHalo(SwayOnb.haloBlue, .22, 260,
                                top: -70, left: -110),
                            _CardHalo(SwayOnb.haloPink, .14, 270,
                                bottom: -110, right: -50),
                          ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 36, 26, 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    switch (art) {
                      SwayTipArt.discoverTiles => const _DiscoverTilesArt(),
                      SwayTipArt.profileRing => const _ProfileRingArt(),
                    },
                    const SizedBox(height: 26),
                    _TipTitle(title),
                    const SizedBox(height: 14),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.dmSans(
                        fontSize: 15,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                        color: SwayOnb.muted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SwayCta(
                      label: buttonLabel,
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                    if (secondaryLabel != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                          foregroundColor: SwayOnb.dim,
                          minimumSize: const Size.fromHeight(40),
                        ),
                        child: Text(
                          secondaryLabel!,
                          style: GoogleFonts.dmSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Titre du coach-mark : dernier mot (hors emoji final) surligné en cyan.
/// L'emoji reste collé à ce mot — sinon il tombe seul sur la ligne suivante.
class _TipTitle extends StatelessWidget {
  const _TipTitle(this.text);

  final String text;

  /// « Ta photo, c'est ici 👇 » → ('Ta photo, ', "c'est ici", ' 👇')
  /// Le surlignage porte sur les deux derniers mots quand le titre en a ≥ 4,
  /// sur le dernier sinon — ce qui donne « Discover » et « c'est ici ».
  (String, String, String) get _parts {
    var t = text.trim();
    var emoji = '';
    final words = t.split(' ');
    if (words.length > 1 && _isEmoji(words.last)) {
      emoji = '\u00A0${words.removeLast()}';
      t = words.join(' ');
    }
    if (words.length >= 4) {
      final tail = words.sublist(words.length - 2).join(' ');
      return ('${words.sublist(0, words.length - 2).join(' ')} ', tail, emoji);
    }
    if (words.length > 1) {
      return ('${words.sublist(0, words.length - 1).join(' ')} ',
          words.last, emoji);
    }
    return ('', t, emoji);
  }

  static bool _isEmoji(String s) =>
      s.isNotEmpty && s.codeUnits.first > 0x2000;

  @override
  Widget build(BuildContext context) {
    final (head, tail, emoji) = _parts;
    final style = GoogleFonts.archivoBlack(
      fontSize: 24,
      height: 1.25,
      letterSpacing: -0.72,
      color: Colors.white,
    );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (head.isNotEmpty) Text(head, style: style),
        DecoratedBox(
          decoration: BoxDecoration(
            color: SC.accent,
            boxShadow: [
              BoxShadow(
                color: SC.accent.withValues(alpha: 0.6),
                blurRadius: 32,
                spreadRadius: -4,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(tail, style: style.copyWith(color: SwayOnb.onAccent)),
          ),
        ),
        if (emoji.isNotEmpty) Text(emoji, style: style),
      ],
    );
  }
}

/// Écran 04 : la rangée de vignettes Discover.
class _DiscoverTilesArt extends StatelessWidget {
  const _DiscoverTilesArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const _SideTile(angle: -9),
          const SizedBox(width: 10),
          SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: SwayOnb.fieldBg,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: SC.accent, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: SC.accent.withValues(alpha: 0.7),
                        blurRadius: 34,
                        spreadRadius: -6,
                      ),
                    ],
                  ),
                  child: const ClipRRect(
                    borderRadius: BorderRadius.all(Radius.circular(21)),
                    child: _AvatarGlyph(headSize: 26, shoulderWidth: 50),
                  ),
                ),
                const Positioned(top: -10, right: -10, child: _PlusBadge()),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const _SideTile(angle: 9),
        ],
      ),
    );
  }
}

class _SideTile extends StatelessWidget {
  const _SideTile({required this.angle});

  final double angle;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle * 3.14159 / 180,
      child: Container(
        width: 52,
        height: 68,
        decoration: BoxDecoration(
          color: SwayOnb.pinBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SwayOnb.pinBorder),
        ),
      ),
    );
  }
}

/// Écran 05 : l'emplacement de photo, anneau pointillé + badge « + ».
class _ProfileRingArt extends StatelessWidget {
  const _ProfileRingArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 118,
      height: 118,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DashedRingPainter(
                color: SC.accent.withValues(alpha: 0.4),
              ),
            ),
          ),
          Positioned.fill(
            left: 13,
            top: 13,
            right: 13,
            bottom: 13,
            child: Container(
              decoration: BoxDecoration(
                color: SwayOnb.fieldBg,
                shape: BoxShape.circle,
                border: Border.all(color: SC.accent, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: SC.accent.withValues(alpha: 0.7),
                    blurRadius: 34,
                    spreadRadius: -6,
                  ),
                ],
              ),
              child: const ClipOval(
                child: _AvatarGlyph(headSize: 28, shoulderWidth: 56),
              ),
            ),
          ),
          const Positioned(top: 6, right: 2, child: _PlusBadge(size: 32)),
        ],
      ),
    );
  }
}

/// Silhouette cyan (tête + épaules) commune aux deux illustrations.
class _AvatarGlyph extends StatelessWidget {
  const _AvatarGlyph({required this.headSize, required this.shoulderWidth});

  final double headSize;
  final double shoulderWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: box.maxHeight * 0.22,
            child: Container(
              width: headSize,
              height: headSize,
              decoration: BoxDecoration(
                color: SC.accent.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            child: Container(
              width: shoulderWidth,
              height: shoulderWidth * 0.54,
              decoration: BoxDecoration(
                color: SC.accent.withValues(alpha: 0.9),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(shoulderWidth),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlusBadge extends StatelessWidget {
  const _PlusBadge({this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SC.accent,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: SC.accent.withValues(alpha: 0.8),
            blurRadius: 24,
            spreadRadius: -4,
          ),
        ],
      ),
      child: Icon(Icons.add_rounded,
          size: size * 0.62, color: SwayOnb.onAccent),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final rect = Offset.zero & size;
    const dash = 0.13; // radians de trait
    const gap = 0.09; // radians de vide
    for (var a = 0.0; a < 6.28318; a += dash + gap) {
      canvas.drawArc(rect, a, dash, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}

/// Halo flou d'angle de carte (même recette que SwayHalo, en plus petit).
class _CardHalo extends StatelessWidget {
  const _CardHalo(this.color, this.opacity, this.size,
      {this.top, this.left, this.right, this.bottom});

  final Color color;
  final double opacity;
  final double size;
  final double? top, left, right, bottom;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }
}
