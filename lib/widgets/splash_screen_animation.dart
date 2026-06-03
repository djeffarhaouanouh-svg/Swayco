import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Premium, Spotify-style boot splash for Swayco — a real-time voice
/// translation app. Pure Flutter (no Lottie, no extra packages): a white
/// "S" mark on pure black, wrapped by a luminous cyan ring that forms,
/// rotates and carries a travelling packet of light around it — the visual
/// metaphor for a message being transmitted and translated in real time,
/// as if the logo were plugged into a worldwide network.
///
/// Timeline
///  • Phase 1 (0.0 – 0.5s) — the logo fades in and zooms 0.9 → 1.0.
///  • Phase 2 (0.5 – 2.0s) — a cyan wisp swirls in and closes into a glowing
///    ring around the logo; the ring slowly rotates with a soft glow.
///  • Phase 3 (loop)       — a light wave travels around the ring while the
///    logo pulses 1.00 → 1.03 → 1.00 and the bottom halo gently breathes.
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

  /// Single cyan accent used for the ring, wave, glow, text and bar.
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
  // One-shot intro: logo in, ring forms, progress fills, status advances.
  late final AnimationController _intro;
  // Continuous orbit: ring rotation + travelling wave (the "message").
  late final AnimationController _orbit;
  // Continuous slow breath: logo pulse + halo intensity.
  late final AnimationController _pulse;

  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoIntroScale;
  late final Animation<double> _ringForm;
  late final Animation<double> _progress;

  // Logo box and the (larger) ring paint box around it.
  static const double _core = 112.0;
  static const double _ring = 190.0;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
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
    // Phase 2 — the ring forms from ~0.5s to 2.0s.
    _ringForm = CurvedAnimation(
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
    _orbit.dispose();
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
                  final intensity = (0.22 + 0.12 * breath) *
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

          // Logo + orbiting ring, dead centre.
          Center(
            child: SizedBox(
              width: _ring,
              height: _ring,
              child: AnimatedBuilder(
                animation: Listenable.merge([_intro, _orbit, _pulse]),
                builder: (context, _) {
                  // Pulse 1.00 → 1.03 → 1.00.
                  final pulseScale =
                      1.0 + 0.015 * (1 - math.cos(_pulse.value * 2 * math.pi));
                  final breath =
                      0.5 - 0.5 * math.cos(_pulse.value * 2 * math.pi);
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Ring / wisp / travelling wave.
                      CustomPaint(
                        size: const Size(_ring, _ring),
                        painter: _OrbitPainter(
                          accent: accent,
                          ringForm: _ringForm.value,
                          orbit: _orbit.value,
                          breath: breath,
                        ),
                      ),
                      // Soft white bloom behind the mark for depth.
                      Opacity(
                        opacity: _logoOpacity.value * 0.5,
                        child: Container(
                          width: _core * 0.95,
                          height: _core * 0.95,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [Color(0x1FFFFFFF), Color(0x00FFFFFF)],
                            ),
                          ),
                        ),
                      ),
                      // The white "S".
                      Opacity(
                        opacity: _logoOpacity.value,
                        child: Transform.scale(
                          scale: _logoIntroScale.value * pulseScale,
                          child: Image.asset(
                            widget.logoAsset,
                            width: _core,
                            height: _core,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ),
                    ],
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

/// Paints the luminous cyan ring, its rotating highlight and the travelling
/// "message" packet (a comet that spirals in while the ring forms, then
/// rides the settled ring).
class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.accent,
    required this.ringForm,
    required this.orbit,
    required this.breath,
  });

  /// 0 → 1: how far the ring has formed (drives opacity + radius snap).
  final double ringForm;

  /// 0 → 1: continuous rotation phase (rotation + wave position).
  final double orbit;

  /// 0 → 1: slow breath used to modulate the glow.
  final double breath;

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final form = ringForm.clamp(0.0, 1.0);
    if (form <= 0) return;

    final center = size.center(Offset.zero);
    final baseR = size.width * 0.5 - 14;
    // Brightest highlights / comet head lean toward white.
    final hot = Color.lerp(accent, Colors.white, 0.65)!;

    // Radius eases from a touch wide to its resting value so the ring looks
    // like it snaps closed around the logo as it forms.
    final ringR = baseR * (1.06 - 0.06 * form);

    // ---- 1. Soft outer glow halo ----
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = accent.withValues(alpha: 0.22 * form * (0.82 + 0.18 * breath))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // ---- 2. Crisp thin track ----
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = accent.withValues(alpha: 0.16 * form),
    );

    // ---- 3. Rotating bright arc (the ring "turns") ----
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          transform: GradientRotation(orbit * 2 * math.pi),
          colors: [
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: 0.55 * form),
            hot.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.55, 0.92, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: ringR)),
    );

    // ---- 4. Travelling wave: a luminous packet circling the ring ----
    // It spirals in from slightly outside while the ring is still forming
    // (the wisp that wraps the logo in the reference), then rides the
    // settled ring once formed.
    final waveR = ringR * (1.0 + 0.10 * (1 - form));
    final headA = -math.pi / 2 + orbit * 2 * math.pi;

    // Comet tail — a string of fading dots behind the head.
    const tailCount = 16;
    for (int i = tailCount; i >= 1; i--) {
      final f = i / tailCount; // ~1 at far tail .. ~0 near head
      final a = headA - f * 1.5; // tail spans ~1.5 rad
      final p = Offset(
        center.dx + waveR * math.cos(a),
        center.dy + waveR * math.sin(a),
      );
      final fade = math.pow(1 - f, 1.6).toDouble();
      canvas.drawCircle(
        p,
        1.6 + 1.8 * fade,
        Paint()
          ..color = accent.withValues(alpha: 0.5 * fade * form)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }

    // Comet head — bright near-white core + glow.
    final head = Offset(
      center.dx + waveR * math.cos(headA),
      center.dy + waveR * math.sin(headA),
    );
    canvas.drawCircle(
      head,
      6,
      Paint()
        ..color = accent.withValues(alpha: 0.55 * form)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawCircle(
      head,
      2.6,
      Paint()..color = hot.withValues(alpha: 0.95 * form),
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.ringForm != ringForm ||
      old.orbit != orbit ||
      old.breath != breath ||
      old.accent != accent;
}
