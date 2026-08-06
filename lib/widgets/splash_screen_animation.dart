import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Boot splash for Swayco — renders the `assets/Traduction.json` Lottie
/// animation (cyan + white line-art) centred on pure black.
///
/// Plays through exactly ONCE (no infinite loop) and fires [onComplete] when
/// done, so `main.dart` can hand off to the first real screen. The web boot
/// page (`web/index.html`) plays the SAME Lottie during engine download, so
/// the hand-off from the HTML splash to this one is invisible.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.asset = 'assets/Traduction.json',
    this.background = const Color(0xFF000000),
    this.onComplete,
  });

  /// Lottie animation rendered at the centre of the screen.
  final String asset;

  /// Pure black by design — matches the web boot page and the app theme.
  final Color background;

  /// Fired once, after the animation has played through a single time.
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
    final size = math.min(shortest * 0.80, 500.0);

    return Scaffold(
      backgroundColor: widget.background,
      body: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Lottie.asset(
            widget.asset,
            // Driven by [_controller] → plays once, then holds the last frame
            // until main.dart swaps in the next screen (never loops).
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
    );
  }
}
