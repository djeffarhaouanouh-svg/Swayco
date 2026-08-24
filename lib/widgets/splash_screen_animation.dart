import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Boot splash for Swayco — plays `assets/splash.json` (Splash Sync Call —
/// cassure nette) centred on pure black.
///
/// Plays through once (no loop) and holds the last frame. `main.dart` keeps
/// the overlay up for at least 3s and until the landing screen is ready, then
/// dismisses it even if the clip is still playing. The web boot page
/// (`web/index.html`) plays the SAME file during engine download.
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
    final size = math.min(shortest * 0.80, 500.0);

    return Scaffold(
      backgroundColor: widget.background,
      body: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Lottie.asset(
            widget.asset,
            controller: _controller,
            fit: BoxFit.contain,
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
