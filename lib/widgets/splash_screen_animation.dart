import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'swayco_wordmark.dart';

/// Fond bleu de la DA 8c : cyan en haut, bleu franc en bas (11a).
const LinearGradient kSplashBlueGradient = LinearGradient(
  begin: Alignment(0.34, -1),
  end: Alignment(-0.34, 1),
  colors: [Color(0xFF18DDEA), Color(0xFF2B7FFF), Color(0xFF1F5EFF)],
  stops: [0, 0.48, 1],
);

/// Rend le fond noir du Lottie transparent : l'opacité devient la luminosité
/// du pixel et la couleur reste blanche. Le logo (blanc) est conservé tel quel,
/// le noir plein cadre disparaît et laisse voir le dégradé.
const ColorFilter kBlackToTransparent = ColorFilter.matrix(<double>[
  0, 0, 0, 0, 255,
  0, 0, 0, 0, 255,
  0, 0, 0, 0, 255,
  0.299, 0.587, 0.114, 0, 0,
]);

/// Jaune de la DA 8c (le « ø » du mot swaycø).
const Color kSplashYellow = Color(0xFFF4FF1F);

/// Boot splash for Swayco — plays `assets/discover_filter_transition.json` (Splash Sync Call —
/// cassure nette) centred on the blue brand gradient (8c).
///
/// Plays through once (no loop) and holds the last frame. `main.dart` keeps
/// the overlay up for at least 3s and until the landing screen is ready, then
/// dismisses it even if the clip is still playing. This is the only player.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.asset = 'assets/discover_filter_transition.json',
    this.gradient = kSplashBlueGradient,
    this.onComplete,
  });

  /// Lottie composition rendered at the centre of the screen.
  final String asset;

  /// Fond du splash : dégradé bleu de marque (avant : noir pur).
  final Gradient gradient;

  /// Optional. Boot does **not** wait on this — the overlay is dismissed by
  /// `main.dart` when the landing screen is ready, even mid-playback.
  final VoidCallback? onComplete;

  @override
  State<SplashScreenAnimation> createState() => _SplashScreenAnimationState();
}

class _SplashScreenAnimationState extends State<SplashScreenAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onComplete?.call();
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final size = math.min(shortest * 0.92, 640.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: widget.gradient),
        child: Stack(
        children: [
          Center(
            child: SizedBox(
              width: size,
              height: size,
              child: ColorFiltered(
                colorFilter: kBlackToTransparent,
                child: Lottie.asset(
                widget.asset,
                controller: _controller,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                onLoaded: (composition) {
                  if (_started) return;
                  _started = true;
                  _controller
                    // Joué 1,2× plus vite que la vitesse d'origine du clip.
                    ..duration = composition.duration * (1 / 1.2)
                    ..forward();
                },
                ),
              ),
            ),
          ),
          // Wordmark anchored to the real bottom of the screen (safe area),
          // independent of the Lottie's own square box — the square sits
          // centred well above the physical bottom edge, so baking the
          // wordmark into the composition itself would strand it mid-screen.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: Center(
                  // Fades in after the ring's own entrance instead of
                  // popping in on frame 0, ahead of the icon animating in.
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _controller,
                      curve: const Interval(0.08, 0.32, curve: Curves.easeOut),
                    ),
                    // « swayc » blanc + « ø » jaune.
                    child: const SwaycoWordmark(
                      fontSize: 20,
                      oColor: kSplashYellow,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}
