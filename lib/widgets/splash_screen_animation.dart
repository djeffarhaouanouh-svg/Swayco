import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Premium, Spotify-style boot splash for Swayco — a real-time voice
/// translation app. Pure Flutter (no Lottie, no extra packages): a large
/// white "S" mark on pure black, wrapped by cyan contour "waves" that
/// ripple outward from the logo — the visual metaphor for a message being
/// transmitted and translated in real time, radiating out to a worldwide
/// network.
///
/// Timeline
///  • Phase 1 (0.0 – 0.5s) — the logo fades in and zooms 0.9 → 1.0.
///  • Phase 2 (0.5 – 2.0s) — cyan contour rings form, hugging the logo, and
///    start rippling outward with a soft glow.
///  • Phase 3 (loop)       — waves continuously emanate from the logo while
///    it pulses 1.00 → 1.03 → 1.00 and the bottom halo gently breathes.
///
/// Faithful to assets/loader-spofitylike.png: a status line that advances
/// ("Connexion…" → "Prêt à traduire"), a thin cyan progress bar and a cyan
/// glow pooling at the bottom of the screen.
///
/// Self-contained: drop it in wherever a boot/loading state is shown. It
/// loops forever, so it works for any boot duration.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.logoAsset = 'assets/notif-android.png',
    this.background = const Color(0xFF000000),
    this.accent = const Color(0xFF22D3EE),
    this.messages = const <String>[
      'Connecter les gens, traduire le monde.',
      'Connexion…',
      'Prêt à traduire',
    ],
    this.showText = true,
    this.showProgress = true,
  });

  /// White, transparent-background logo mark shown at the centre.
  final String logoAsset;

  /// Pure black by design — the premium look depends on it.
  final Color background;

  /// Single cyan accent used for the waves, glow, text and bar.
  final Color accent;

  /// Status line, advanced over the intro: [intro, connecting, ready].
  final List<String> messages;

  final bool showText;
  final bool showProgress;

  @override
  State<SplashScreenAnimation> createState() => _SplashScreenAnimationState();
}

class _SplashScreenAnimationState extends State<SplashScreenAnimation>
    with TickerProviderStateMixin {
  // One-shot intro: logo in, waves form, progress fills, status advances.
  late final AnimationController _intro;
  // Continuous emanation: contour waves rippling outward from the logo.
  late final AnimationController _wave;
  // Continuous slow breath: logo pulse + halo / glow intensity.
  late final AnimationController _pulse;

  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoIntroScale;
  late final Animation<double> _waveForm;
  late final Animation<double> _progress;

  // Logo box — large and centred.
  static const double _core = 168.0;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4800),
    )..repeat();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();

    // Phase 1 — fade + zoom 0.9 → 1.0 in the first ~0.5s.
    _logoOpacity = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.0, 0.26, curve: Curves.easeOut),
    );
    _logoIntroScale = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.0, 0.34, curve: Curves.easeOutCubic),
      ),
    );
    // Phase 2 — the contour waves fade in from ~0.5s to 2.0s.
    _waveForm = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.22, 1.0, curve: Curves.easeOutCubic),
    );
    // Progress bar fills across the whole intro.
    _progress = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.04, 1.0, curve: Curves.easeInOut),
    );

    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _wave.dispose();
    _pulse.dispose();
    super.dispose();
  }

  String _statusFor(double t) {
    final m = widget.messages;
    if (m.isEmpty) return '';
    if (t < 0.42) return m.first;
    if (t < 0.86) return m.length > 1 ? m[1] : m.first;
    return m.last;
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;

    return Scaffold(
      backgroundColor: widget.background,
      body: Stack(
        children: [
          // Cyan halo pooling at the bottom — fades in then gently breathes.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([_pulse, _intro]),
                builder: (context, _) {
                  final breath =
                      0.5 - 0.5 * math.cos(_pulse.value * 2 * math.pi);
                  // Kept low so the background reads as a deep, pure black.
                  final intensity = (0.09 + 0.05 * breath) *
                      _intro.value.clamp(0.0, 1.0);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, 1.28),
                        radius: 1.15,
                        colors: [
                          accent.withValues(alpha: intensity),
                          accent.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Contour waves rippling outward from the logo (centre of screen).
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([_intro, _wave, _pulse]),
                builder: (context, _) {
                  final breath =
                      0.5 - 0.5 * math.cos(_pulse.value * 2 * math.pi);
                  return CustomPaint(
                    painter: _WavePainter(
                      accent: accent,
                      form: _waveForm.value,
                      wave: _wave.value,
                      breath: breath,
                    ),
                  );
                },
              ),
            ),
          ),

          // Logo, dead centre, over the waves.
          Center(
            child: SizedBox(
              width: _core,
              height: _core,
              child: AnimatedBuilder(
                animation: Listenable.merge([_intro, _pulse]),
                builder: (context, _) {
                  // Pulse 1.00 → 1.03 → 1.00.
                  final pulseScale =
                      1.0 + 0.015 * (1 - math.cos(_pulse.value * 2 * math.pi));
                  return Opacity(
                    opacity: _logoOpacity.value,
                    child: Transform.scale(
                      scale: _logoIntroScale.value * pulseScale,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          // Soft white bloom for depth.
                          Container(
                            width: _core * 0.86,
                            height: _core * 0.86,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [Color(0x24FFFFFF), Color(0x00FFFFFF)],
                              ),
                            ),
                          ),
                          // Cyan rim light, upper-right (matches reference).
                          Positioned(
                            top: _core * 0.08,
                            right: _core * 0.10,
                            child: Container(
                              width: _core * 0.46,
                              height: _core * 0.46,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    accent.withValues(alpha: 0.26),
                                    accent.withValues(alpha: 0.0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // The white "S".
                          Image.asset(
                            widget.logoAsset,
                            width: _core,
                            height: _core,
                            filterQuality: FilterQuality.high,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Status line + progress bar, lower third.
          if (widget.showText || widget.showProgress)
            Positioned(
              left: 24,
              right: 24,
              bottom: 104,
              child: AnimatedBuilder(
                animation: _intro,
                builder: (context, _) {
                  final t = _intro.value;
                  final status = _statusFor(t);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.showText)
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 420),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: child,
                          ),
                          child: Text(
                            status,
                            key: ValueKey<String>(status),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: accent.withValues(alpha: 0.92),
                              fontSize: 13,
                              height: 1.3,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      if (widget.showText && widget.showProgress)
                        const SizedBox(height: 18),
                      if (widget.showProgress)
                        _ProgressBar(value: _progress.value, accent: accent),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Thin, glowing cyan progress bar — matches the reference loader.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.accent});

  final double value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 132,
      height: 3,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0.04, 1.0),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: LinearGradient(
                colors: [accent.withValues(alpha: 0.6), accent],
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.55),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints cyan, squircle-shaped contour "waves" that hug the logo and
/// ripple continuously outward — born tight around the mark, expanding and
/// fading as they travel out, like sound/translation radiating to a network.
class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.accent,
    required this.form,
    required this.wave,
    required this.breath,
  });

  /// 0 → 1: intro formation (fades the whole wave system in).
  final double form;

  /// 0 → 1: looping emanation phase.
  final double wave;

  /// 0 → 1: slow breath used to modulate the bright inner outline.
  final double breath;

  final Color accent;

  // How many rings are alive at once.
  static const int _count = 7;
  // Tight outline that hugs the logo (a touch larger than the "S").
  static const double _rxHug = 86;
  static const double _ryHug = 108;
  // Squircle exponent — rounded-rectangle feel, like the reference.
  static const double _n = 3.4;

  @override
  void paint(Canvas canvas, Size size) {
    if (form <= 0) return;
    final center = size.center(Offset.zero);
    final hot = Color.lerp(accent, Colors.white, 0.5)!;

    // ---- Emanating contour waves ----
    for (int i = 0; i < _count; i++) {
      final t = (wave + i / _count) % 1.0;
      final ease = Curves.easeOut.transform(t);
      final s = 1.0 + 0.95 * ease; // 1.0 → ~1.95 outward
      final fadeIn = (t / 0.10).clamp(0.0, 1.0); // born softly at the logo
      final fadeOut = math.pow(1 - t, 1.3).toDouble(); // dim as it travels
      final alpha = 0.36 * fadeIn * fadeOut * form;
      if (alpha <= 0.004) continue;

      final path = _squircle(center, _rxHug * s, _ryHug * s);
      // Soft glow underlay.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0
          ..color = accent.withValues(alpha: alpha * 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      // Crisp contour.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.6 - 0.8 * t).clamp(0.7, 1.6)
          ..color = accent.withValues(alpha: alpha),
      );
    }

    // ---- Bright outline hugging the logo (anchors the waves) ----
    final hug = _squircle(center, _rxHug, _ryHug);
    canvas.drawPath(
      hug,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = accent.withValues(alpha: 0.18 * form * (0.8 + 0.2 * breath))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawPath(
      hug,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = hot.withValues(alpha: 0.5 * form),
    );
  }

  /// Closed squircle (super-ellipse) path centred on [c].
  Path _squircle(Offset c, double rx, double ry) {
    const steps = 96;
    final path = Path();
    for (int i = 0; i <= steps; i++) {
      final th = (i / steps) * 2 * math.pi;
      final x = c.dx + rx * _sgnPow(math.cos(th), 2 / _n);
      final y = c.dy + ry * _sgnPow(math.sin(th), 2 / _n);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  double _sgnPow(double v, double p) =>
      (v < 0 ? -1.0 : 1.0) * math.pow(v.abs(), p).toDouble();

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.form != form ||
      old.wave != wave ||
      old.breath != breath ||
      old.accent != accent;
}
