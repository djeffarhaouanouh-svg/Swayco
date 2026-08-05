import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Boot splash — full-bleed `assets/icons/splash_screen.png` (gradient + coconut).
///
/// Fades in once, holds briefly, then fires [onComplete] so `main.dart` can
/// hand off. The web boot page shows the same art during engine download.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.onComplete,
  });

  /// Fired once after the entrance animation settles.
  final VoidCallback? onComplete;

  static const splashAsset = 'assets/icons/splash_screen.png';

  @override
  State<SplashScreenAnimation> createState() => _SplashScreenAnimationState();
}

class _SplashScreenAnimationState extends State<SplashScreenAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_completed) {
        _completed = true;
        Future<void>.delayed(const Duration(milliseconds: 550), () {
          if (mounted) widget.onComplete?.call();
        });
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Match the art's square composition without letterboxing on tall phones:
    // cover the viewport; the coconut stays centred in the PNG.
    final size = MediaQuery.sizeOf(context);
    final side = math.max(size.width, size.height);

    return ColoredBox(
      color: const Color(0xFF5AD0D8), // fallback under the gradient art
      child: FadeTransition(
        opacity: _fade,
        child: Center(
          child: Image.asset(
            SplashScreenAnimation.splashAsset,
            width: side,
            height: side,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
