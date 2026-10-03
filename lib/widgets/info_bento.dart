import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Une tuile du bento « Mes infos » : emoji + libellé, valeur, et — sur mon
/// profil — l'action qui ouvre le choix.
class BentoTileData {
  const BentoTileData({
    required this.emoji,
    required this.label,
    required this.value,
    this.onTap,
  });

  final String emoji;

  /// Libellé de la tuile (affiché en majuscules).
  final String label;

  /// Vide = champ non renseigné.
  final String value;

  /// Tap : ouvre l'édition (mon profil). Null = lecture seule.
  final Future<void> Function(BuildContext)? onTap;

  bool get filled => value.trim().isNotEmpty;
}

/// Les faits du profil en « bento » : la grande tuile Âge (dégradé de marque) à
/// gauche, deux tuiles empilées à droite, puis les autres deux par deux.
///
/// [editable] (mon profil) : toutes les tuiles s'affichent, les vides en
/// « Ajouter » pointillé. Sinon (chez un pair, sur la carte Discover) une
/// tuile sans valeur disparaît et la grille se recompose.
class InfoBento extends StatelessWidget {
  const InfoBento({
    super.key,
    required this.age,
    required this.others,
    this.editable = false,
  });

  final BentoTileData age;
  final List<BentoTileData> others;
  final bool editable;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final showAge = editable || age.filled;
    final smalls = [
      for (final t in others)
        if (editable || t.filled) t,
    ];
    if (!showAge && smalls.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];
    var rest = smalls;
    if (showAge) {
      final right = smalls.take(2).toList();
      rest = smalls.skip(right.length).toList();
      rows.add(
        right.isEmpty
            ? _AgeTile(data: age, editable: editable)
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _AgeTile(data: age, editable: editable)),
                    const SizedBox(width: _gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < right.length; i++) ...[
                            if (i > 0) const SizedBox(height: _gap),
                            Expanded(child: _InfoTile(data: right[i])),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      );
    }
    for (var i = 0; i < rest.length; i += 2) {
      final pair = rest.sublist(i, math.min(i + 2, rest.length));
      rows.add(
        pair.length == 1
            ? _InfoTile(data: pair[0])
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _InfoTile(data: pair[0])),
                    const SizedBox(width: _gap),
                    Expanded(child: _InfoTile(data: pair[1])),
                  ],
                ),
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: _gap),
          rows[i],
        ],
      ],
    );
  }
}

/// Style du petit libellé de tuile : mono, majuscules, blanc 55 %.
TextStyle bentoLabelStyle() => GoogleFonts.ibmPlexMono(
      fontSize: 11,
      letterSpacing: 1.1,
      color: SC.light ? SC.textMuted : Colors.white.withValues(alpha: 0.55),
    );

/// Le cadre d'une tuile « verre » : rayon 20, fond blanc 10 %, bord blanc 16 %.
BoxDecoration bentoTileDecoration() => BoxDecoration(
      color: SC.light ? SC.menu : Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: SC.light ? SC.glassBorder : Colors.white.withValues(alpha: 0.16),
      ),
    );

class _AgeTile extends StatelessWidget {
  const _AgeTile({required this.data, required this.editable});

  final BentoTileData data;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final filled = data.filled;
    final unit = AppStrings.t('info_age_value', args: {'n': ''}).trim();
    final tile = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 150),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment(-0.34, -0.94),
            end: Alignment(0.34, 0.94),
            colors: [Color(0xBF1F5EFF), Color(0x992B7FFF), Color(0x8C18DDEA)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(data.emoji, style: const TextStyle(fontSize: 22, height: 1)),
            if (filled)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.value,
                    maxLines: 1,
                    style: popupDisplay(
                      fontSize: 46,
                      letterSpacing: -2.3,
                      height: 1,
                      color: Colors.white,
                    ),
                  ),
                  if (unit.isNotEmpty)
                    Text(
                      unit,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              )
            else
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      color: SC.accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      size: 22,
                      color: SC.onAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      data.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
    return _tappable(context, data, tile);
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.data});

  final BentoTileData data;

  @override
  Widget build(BuildContext context) {
    final filled = data.filled;
    final content = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${data.emoji} ${data.label.toUpperCase()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: bentoLabelStyle(),
          ),
          const SizedBox(height: 4),
          Text(
            filled ? data.value : AppStrings.t('info_add'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              // Clair : le jaune n'est pas lisible sur blanc — la valeur passe en encre.
              color: filled
                  ? (SC.light ? SC.textPrimary : SC.accent)
                  : (SC.light ? SC.textMuted : Colors.white.withValues(alpha: 0.45)),
              fontSize: 16,
              height: 1.2,
              fontWeight: filled ? FontWeight.w800 : FontWeight.w500,
              fontStyle: filled ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        ],
      ),
    );
    final tile = filled
        ? Container(
            constraints: const BoxConstraints(minHeight: 76),
            decoration: bentoTileDecoration(),
            alignment: Alignment.centerLeft,
            child: content,
          )
        : ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 76),
            child: CustomPaint(
              painter: _DashedTilePainter(SC.accentFg.withValues(alpha: 0.6)),
              child: Align(alignment: Alignment.centerLeft, child: content),
            ),
          );
    return _tappable(context, data, tile);
  }
}

Widget _tappable(BuildContext context, BentoTileData data, Widget child) {
  final tap = data.onTap;
  if (tap == null) return child;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => tap(context),
    child: child,
  );
}

/// Bord pointillé jaune d'une tuile vide (rayon 20), fond blanc 6 %.
class _DashedTilePainter extends CustomPainter {
  const _DashedTilePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      const Radius.circular(20),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = SC.light
            ? SC.glass
            : Colors.white.withValues(alpha: 0.05),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in (Path()..addRRect(rrect)).computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedTilePainter old) => old.color != color;
}

/// Le cadre en verre de « Mes infos » : rayon 26, padding 14, flou 28, fond
/// blanc 10 %, bord blanc 24 % de 1,2 px — le verre de la barre de navigation.
class InfoGlassFrame extends StatelessWidget {
  const InfoGlassFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(26);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: SC.light
                ? const Color(0xB8FFFFFF)
                : Colors.white.withValues(alpha: 0.10),
            borderRadius: r,
            border: Border.all(
              color: SC.light
                  ? SC.glassBorder
                  : Colors.white.withValues(alpha: 0.24),
              width: 1.2,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}