// ─────────────────────────────────────────────────────────────────────────────
// sway_tip_dialog.dart — écrans 04 (Discover) et 05 (Profil, version finale)
//
// Où le mettre :  lib/widgets/sway_tip_dialog.dart  (remplace le fichier livré
//                 précédemment — même API, illustration 05 mise à jour)
// Dépend de :     lib/widgets/sway_onb_kit.dart
// Dépendances pubspec : aucune nouvelle.
//
// ── PATCH — lib/screens/root_shell.dart (inchangé) ──────────────────────────
// 1. import '../widgets/sway_tip_dialog.dart';
// 2. corps de _showTip :
//
//      Future<void> _showTip({
//        required IconData icon,
//        required String title,
//        required String body,
//        required String buttonLabel,
//        String? imageAsset,
//        SwayTipArt art = SwayTipArt.addsPile,
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
// 3. premier tip (photo) : ajouter `art: SwayTipArt.discoverTiles`.
//    Les tips `tip_photo_where_*` et `tip_profile_here_*` gardent le défaut
//    SwayTipArt.addsPile (= écran 05).
// 4. `_TipDialog`, assets/add-picture.png et son precacheImage : supprimables.
//
// ⚠️ Textes : sur l'écran 05 la maquette met le bénéfice dans la phrase grise
// (« Ajoute ta photo, pour recevoir plein d'ajout. ») et le titre reste
// « Ta photo, c'est ici » — sans emoji 👇, l'illustration ayant changé.
// Mets à jour tip_profile_here_body / tip_photo_where_body en conséquence.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/swayco_theme.dart';
import 'sway_onb_kit.dart';

enum SwayTipArt {
  /// Écran 04 — rangée de vignettes Discover, celle du centre en avant.
  discoverTiles,

  /// Écran 05 — la pile de demandes d'ajout reçues (bénéfice).
  addsPile,
}

/// Coach-mark 1e : carte noire à halos, titre surligné cyan, CTA plein.
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
    final discover = art == SwayTipArt.discoverTiles;
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
              Positioned.fill(
                child: ClipRect(
                  child: Stack(
                    children: discover
                        ? const [
                            _CardHalo(SwayOnb.haloCyan, .26, 320, top: -130, left: -90),
                            _CardHalo(SwayOnb.haloBlue, .22, 260, top: -60, right: -110),
                            _CardHalo(SwayOnb.haloPink, .14, 270, bottom: -110, left: -50),
                          ]
                        : const [
                            _CardHalo(SwayOnb.haloCyan, .26, 320, top: -130, right: -90),
                            _CardHalo(SwayOnb.haloBlue, .22, 260, top: -70, left: -110),
                            _CardHalo(SwayOnb.haloPink, .14, 270, bottom: -110, right: -50),
                          ],
                  ),
                ),
              ),
              // Rythme : 32 de marge haute, 26 entre les blocs.
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 32, 26, 26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Écran 04 : illustration au-dessus du texte.
                    if (discover) ...[
                      const _DiscoverTilesArt(),
                      const SizedBox(height: 26),
                    ],
                    _TipTitle(title),
                    const SizedBox(height: 12),
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
                    // Écran 05 : la pile s'intercale entre la phrase et le CTA.
                    if (!discover) ...[
                      const SizedBox(height: 26),
                      const _AddsPileArt(),
                    ],
                    const SizedBox(height: 26),
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
                              fontSize: 14, fontWeight: FontWeight.w500),
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

/// Titre du coach-mark : la fin du titre est surlignée en cyan.
class _TipTitle extends StatelessWidget {
  const _TipTitle(this.text);

  final String text;

  (String, String) get _parts {
    final words = text.trim().split(' ');
    if (words.length >= 4) {
      final tail = words.sublist(words.length - 2).join(' ');
      return ('${words.sublist(0, words.length - 2).join(' ')} ', tail);
    }
    if (words.length > 1) {
      return ('${words.sublist(0, words.length - 1).join(' ')} ', words.last);
    }
    return ('', text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final (head, tail) = _parts;
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
      ],
    );
  }
}

// ── Écran 05 : la pile de demandes ──────────────────────────────────────────

/// Carte « Léa veut t'ajouter » posée sur deux cartes qui reculent.
class _AddsPileArt extends StatelessWidget {
  const _AddsPileArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            top: 36,
            child: _RearLayer(width: 188, height: 46, opacity: .6,
                fill: Color(0xFF14181D), border: SwayOnb.fieldBorder),
          ),
          Positioned(
            top: 20,
            child: _RearLayer(width: 222, height: 50, opacity: .9,
                fill: Color(0xFF12161A), border: Color(0xFF262B31)),
          ),
          const Positioned(top: 0, child: _FrontRequestCard()),
        ],
      ),
    );
  }
}

class _RearLayer extends StatelessWidget {
  const _RearLayer({
    required this.width,
    required this.height,
    required this.opacity,
    required this.fill,
    required this.border,
  });

  final double width, height, opacity;
  final Color fill, border;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: border),
        ),
      ),
    );
  }
}

class _FrontRequestCard extends StatelessWidget {
  const _FrontRequestCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 258,
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: SwayOnb.fieldBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SwayOnb.pinBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0xE6000000),
            blurRadius: 34,
            spreadRadius: -16,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: Color(0xFF191D22),
              shape: BoxShape.circle,
            ),
            child: const ClipOval(
              child: Image(
                image: AssetImage('assets/tips/lea_preview.jpg'),
                width: 34,
                height: 34,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Léa',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFE6EBEF),
                  ),
                ),
                Text(
                  "veut t'ajouter",
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: SwayOnb.dim,
                  ),
                ),
              ],
            ),
          ),
          const _HeartCounter(
            label: '+248',
            // Même rouge que le cœur "a aimé ta photo" des Likes reçus —
            // pas un nouveau ton inventé pour ce dialogue.
            color: Color(0xFFFF3B5C),
          ),
        ],
      ),
    );
  }
}

/// Compteur d'ajouts : cœur cyan, chiffre sombre dedans.
class _HeartCounter extends StatefulWidget {
  const _HeartCounter({required this.label, this.color = SC.accent});

  final String label;

  /// Couleur du cœur. Le chiffre reste blanc dessus (lisible sur rouge
  /// comme sur cyan), contrairement à `SwayOnb.onAccent` qui suppose un
  /// fond clair — ce token est partagé par d'autres éléments cyan de
  /// l'onboarding et ne doit pas changer pour eux.
  final Color color;

  @override
  State<_HeartCounter> createState() => _HeartCounterState();
}

class _HeartCounterState extends State<_HeartCounter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  /// Un battement de cœur — deux pulsations puis une pause — pas un rebond
  /// continu qui fatiguerait l'œil sur une carte statique.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.16)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 10,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.16, end: 1.0)
          .chain(CurveTween(curve: Curves.easeIn)),
      weight: 10,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.10)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 9,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.10, end: 1.0)
          .chain(CurveTween(curve: Curves.easeIn)),
      weight: 9,
    ),
    TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 62),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scale,
      builder: (context, child) =>
          Transform.scale(scale: _scale.value, child: child),
      child: SizedBox(
        // Le chiffre remplissait le cœur bord à bord : élargi (même rapport
        // largeur/hauteur, le dessin n'est pas déformé) pour lui rendre de l'air.
        width: 50,
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _HeartPainter(color: widget.color)),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                widget.label,
                style: GoogleFonts.archivoBlack(
                  fontSize: 12,
                  letterSpacing: -0.24,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeartPainter extends CustomPainter {
  const _HeartPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.97)
      ..cubicTo(w * 0.02, h * 0.66, w * 0.02, h * 0.30, w * 0.24, h * 0.10)
      ..cubicTo(w * 0.38, h * -0.01, w * 0.47, h * 0.09, w * 0.5, h * 0.16)
      ..cubicTo(w * 0.53, h * 0.09, w * 0.62, h * -0.01, w * 0.76, h * 0.10)
      ..cubicTo(w * 0.98, h * 0.30, w * 0.98, h * 0.66, w * 0.5, h * 0.97)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 8),
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_HeartPainter old) => old.color != color;
}

// ── Écran 04 : la rangée Discover ───────────────────────────────────────────

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
                    child: _AvatarGlyph(headSize: 26, shoulderWidth: 50, white: true),
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

/// Silhouette tête + épaules. `white: true` = version blanche de la maquette.
class _AvatarGlyph extends StatelessWidget {
  const _AvatarGlyph({
    required this.headSize,
    required this.shoulderWidth,
    this.white = false,
  });

  final double headSize;
  final double shoulderWidth;
  final bool white;

  @override
  Widget build(BuildContext context) {
    final color = (white ? Colors.white : SC.accent).withValues(alpha: 0.9);
    return LayoutBuilder(
      builder: (context, box) => Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: box.maxHeight * 0.22,
            child: Container(
              width: headSize,
              height: headSize,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          Positioned(
            bottom: 0,
            child: Container(
              width: shoulderWidth,
              height: shoulderWidth * 0.54,
              decoration: BoxDecoration(
                color: color,
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
      child: Icon(Icons.add_rounded, size: size * 0.62, color: SwayOnb.onAccent),
    );
  }
}

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
