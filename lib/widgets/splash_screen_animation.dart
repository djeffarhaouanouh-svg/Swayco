import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../theme/swayco_theme.dart';

/// Boot splash for Swayco — plays `assets/splash.json` (Splash Sync Call —
/// cassure nette) centred on pure black.
///
/// Plays through once (no loop) and holds the last frame. `main.dart` keeps
/// the overlay up for at least 3s and until the landing screen is ready, then
/// dismisses it even if the clip is still playing. This is the only player.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.asset = 'assets/splash.json',
    this.background = const Color(0xFF000000),
    this.onComplete,
  });

  /// Lottie composition rendered at the centre of the screen.
  final String asset;

  /// Pure black by design — matches the web boot page and the app theme.
  final Color background;

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
      backgroundColor: widget.background,
      body: Stack(
        children: [
          Center(
            child: SizedBox(
              width: size,
              height: size,
              child: Lottie.asset(
                widget.asset,
                controller: _controller,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                onLoaded: (composition) {
                  if (_started) return;
                  _started = true;
                  _controller
                    ..duration = composition.duration
                    ..forward();
                },
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
                    child: Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'swayc'),
                          TextSpan(
                            text: 'ø',
                            style: TextStyle(color: SC.accent),
                          ),
                        ],
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: SC.brandFont,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
