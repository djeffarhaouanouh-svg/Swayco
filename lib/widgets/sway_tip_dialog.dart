import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

enum SwayTipArt {
  /// Rangée de vignettes Discover, celle du centre en avant (pas de photo).
  discoverTiles,

  /// Pile de demandes d'ajout reçues (bénéfice d'ajouter sa photo).
  addsPile,
}

/// Coach-mark « ajoute ta photo » (direction 8c). Même API qu'avant :
/// pop `true` sur le bouton principal, `false` sur le lien secondaire.
/// Ne dépend plus de sway_onb_kit.dart.
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
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22),
      child: PopupSurface(
        washHeight: 170,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 32, 26, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (discover) ...[
                const _DiscoverTilesArt(),
                const SizedBox(height: 26),
              ],
              _TipTitle(title),
              const SizedBox(height: 12),
              PopupBody(body),
              if (!discover) ...[
                const SizedBox(height: 26),
                const _AddsPileArt(),
              ],
              const SizedBox(height: 26),
              PopupButton(
                label: buttonLabel,
                height: 54,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              if (secondaryLabel != null) ...[
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    minimumSize: const Size.fromHeight(40),
                  ),
                  child: Text(
                    secondaryLabel!,
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Titre sur deux lignes : le début, puis la fin (2 mots si 4 mots ou plus)
/// sur une pastille jaune — « Ta photo, / [c'est ici] ».
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
    final style = popupDisplay(
      fontSize: 22,
      fontWeight: FontWeight.w800,
      height: 1.25,
      letterSpacing: -0.66,
      color: Colors.white,
    );
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          // Forced break: the pill always opens the second line.
          if (head.isNotEmpty) TextSpan(text: '${head.trimRight()}\n'),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: SC.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(tail, style: style.copyWith(color: SC.onAccent)),
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

// ── Pile de demandes ────────────────────────────────────────────────────────

class _AddsPileArt extends StatelessWidget {
  const _AddsPileArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: Stack(
        alignment: Alignment.topCenter,
        children: const [
          Positioned(
            top: 36,
            child: _RearLayer(width: 188, height: 46, opacity: .55),
          ),
          Positioned(
            top: 20,
            child: _RearLayer(width: 222, height: 50, opacity: .85),
          ),
          Positioned(top: 0, child: _FrontRequestCard()),
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
  });

  final double width, height, opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF1D1D24),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: PopupTokens.border),
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
        color: const Color(0xFF23232B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PopupTokens.ghostBorder),
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
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: SC.brandGradient,
            ),
            child: const ClipOval(
              child: Image(
                image: AssetImage('assets/tips/lea_preview.jpg'),
                width: 32,
                height: 32,
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
                  style: GoogleFonts.dmSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                Text(
                  "veut t'ajouter",
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          // Même rouge que le cœur « a aimé ta photo » des Likes reçus.
          const _HeartCounter(label: '+248', color: Color(0xFFFF6B8A)),
        ],
      ),
    );
  }
}

class _HeartCounter extends StatefulWidget {
  const _HeartCounter({required this.label, required this.color});

  final String label;
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

  /// Un battement de cœur : deux pulsations puis une pause.
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
                style: popupDisplay(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
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

// ── Rangée Discover ─────────────────────────────────────────────────────────

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
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    gradient: SC.brandGradient,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: SC.brandBlue.withValues(alpha: 0.7),
                        blurRadius: 34,
                        spreadRadius: -6,
                      ),
                    ],
                  ),
                  child: const ClipRRect(
                    borderRadius: BorderRadius.all(Radius.circular(19.5)),
                    child: ColoredBox(
                      color: Color(0xFF0E0E0E),
                      child: _AvatarGlyph(headSize: 26, shoulderWidth: 50),
                    ),
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
          color: PopupTokens.ghost,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: PopupTokens.ghostBorder),
        ),
      ),
    );
  }
}

/// Silhouette tête + épaules, blanche.
class _AvatarGlyph extends StatelessWidget {
  const _AvatarGlyph({required this.headSize, required this.shoulderWidth});

  final double headSize;
  final double shoulderWidth;

  @override
  Widget build(BuildContext context) {
    final color = Colors.white.withValues(alpha: 0.9);
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
  const _PlusBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SC.accent,
        shape: BoxShape.circle,
        border: Border.all(color: PopupTokens.surface, width: 3),
        boxShadow: [
          BoxShadow(
            color: SC.accent.withValues(alpha: 0.6),
            blurRadius: 20,
            spreadRadius: -4,
          ),
        ],
      ),
      child: const Icon(Icons.add_rounded, size: 18, color: SC.onAccent),
    );
  }
}

