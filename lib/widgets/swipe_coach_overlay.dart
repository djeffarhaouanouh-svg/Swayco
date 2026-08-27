// swipe_coach_overlay.dart — le coach « glisse pour choisir », montré une
// seule fois : à la toute fin de l'onboarding, quand l'utilisateur arrive
// sur le Discover pour la première fois.
//
// Attention au sens : dans Swayco le geste est INVERSÉ par rapport à la
// convention Tinder (voir `_onCardSwiped` dans discover_screen.dart) —
// glisser à GAUCHE, c'est aimer ; à DROITE, c'est passer. L'animation et
// les textes suivent cette règle, pas l'habitude.
//
// Le parent affiche l'overlay dans un Stack et le retire dans [onDismiss].

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'sway_onb_kit.dart';

class SwipeCoachOverlay extends StatefulWidget {
  const SwipeCoachOverlay({
    super.key,
    this.speedSeconds = 4.0,
    this.onDismiss,
  });

  /// Durée d'un cycle complet gauche + droite.
  final double speedSeconds;

  /// Appelé au premier tap : le parent retire l'overlay et pose le flag.
  final VoidCallback? onDismiss;

  @override
  State<SwipeCoachOverlay> createState() => _SwipeCoachOverlayState();
}

class _SwipeCoachOverlayState extends State<SwipeCoachOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _fade;
  bool _open = true;

  // Couleurs des tampons LIKE / NOPE de la carte Discover : le coach parle
  // le même langage que l'écran qu'il explique.
  static const _like = Color(0xFF3DCA72);
  static const _nope = Color(0xFFFF4458);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (widget.speedSeconds * 1000).round()),
    )..repeat();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _fade.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (!_open) return;
    _open = false;
    await _fade.reverse();
    if (!mounted) return;
    widget.onDismiss?.call();
  }

  /// Décalage horizontal de la carte, en px : reprise de la timeline
  /// d'origine (0-100 %). Négatif d'abord — le like part à gauche.
  double _cardDx(double t) {
    if (t < 0.12) return 0;
    if (t < 0.30) return _lerp(0, -104, (t - 0.12) / 0.18);
    if (t < 0.42) return -104;
    if (t < 0.50) return _lerp(-104, 0, (t - 0.42) / 0.08);
    if (t < 0.62) return 0;
    if (t < 0.80) return _lerp(0, 104, (t - 0.62) / 0.18);
    if (t < 0.92) return 104;
    return _lerp(104, 0, (t - 0.92) / 0.08);
  }

  double _lerp(double a, double b, double f) => a + (b - a) * f.clamp(0, 1);

  double _pulse(double t, double center, double width) {
    final d = (t - center).abs();
    if (d > width) return 0;
    return 1 - (d / width);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          child: Container(
            color: Colors.black.withValues(alpha: .82),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = _controller.value;
                final dx = _cardDx(t);
                final rotation = dx * 9 / 104 * math.pi / 180;
                final handScale = 1 - 0.14 * (dx.abs() / 104);
                final leftActive = (t >= 0.30 && t <= 0.44) ? 1.0 : 0.28;
                final rightActive = (t >= 0.80 && t <= 0.94) ? 1.0 : 0.28;
                final ring =
                    math.max(_pulse(t, 0.14, 0.07), _pulse(t, 0.64, 0.07));

                return SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 288,
                            height: 260,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Gauche = j'aime.
                                Positioned(
                                  left: 0,
                                  child: _SideHint(
                                    icon: Icons.favorite_rounded,
                                    color: _like,
                                    label: AppStrings.t('swipe_coach_like'),
                                    opacity: leftActive,
                                  ),
                                ),
                                // Droite = je passe.
                                Positioned(
                                  right: 0,
                                  child: _SideHint(
                                    icon: Icons.close_rounded,
                                    color: _nope,
                                    label: AppStrings.t('swipe_coach_pass'),
                                    opacity: rightActive,
                                  ),
                                ),
                                Transform.translate(
                                  offset: Offset(dx, 0),
                                  child: Transform.rotate(
                                    angle: rotation,
                                    child: Container(
                                      width: 172,
                                      height: 236,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.white
                                              .withValues(alpha: .85),
                                          width: 1.5,
                                        ),
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                    ),
                                  ),
                                ),
                                Transform.translate(
                                  offset: Offset(dx, 0),
                                  child: Transform.scale(
                                    scale: handScale,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Opacity(
                                          opacity: ring * .55,
                                          child: Container(
                                            width: 76,
                                            height: 76,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: SC.accent,
                                                width: 1.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const Text('\u{1F446}',
                                            style: TextStyle(fontSize: 64)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              AppStrings.t('swipe_coach_title'),
                              textAlign: TextAlign.center,
                              style: GoogleFonts.archivoBlack(
                                fontSize: 24,
                                height: 1.15,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              AppStrings.t('swipe_coach_body'),
                              textAlign: TextAlign.center,
                              style: GoogleFonts.dmSans(
                                fontSize: 15,
                                height: 1.5,
                                fontWeight: FontWeight.w500,
                                color: SwayOnb.muted,
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            AppStrings.t('swipe_coach_cta').toUpperCase(),
                            textAlign: TextAlign.center,
                            style: GoogleFonts.dmSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.4,
                              color: Colors.white.withValues(alpha: .5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Repère latéral : l'icône du geste et son mot. Il s'allume pile au moment
/// où la carte part de ce côté-là.
class _SideHint extends StatelessWidget {
  const _SideHint({
    required this.icon,
    required this.color,
    required this.label,
    required this.opacity,
  });

  final IconData icon;
  final Color color;
  final String label;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: opacity,
      duration: const Duration(milliseconds: 160),
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 6),
            Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmSans(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: .8,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
