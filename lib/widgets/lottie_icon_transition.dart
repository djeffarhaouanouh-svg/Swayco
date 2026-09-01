import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Plays a square Lottie icon once, centred on a solid background — no
/// wordmark, unlike [SplashScreenAnimation]. For in-app transitions (e.g. the
/// Discover globe filter's "Go" confirmation), not the app boot splash.
class LottieIconTransition extends StatefulWidget {
  const LottieIconTransition({
    super.key,
    required this.asset,
    this.background = const Color(0xFF000000),
    this.onComplete,
  });

  /// Lottie composition rendered at the centre.
  final String asset;

  final Color background;

  /// Fired once, after the animation has played through a single time.
  final VoidCallback? onComplete;

  @override
  State<LottieIconTransition> createState() => _LottieIconTransitionState();
}

class _LottieIconTransitionState extends State<LottieIconTransition>
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

    return Container(
      color: widget.background,
      alignment: Alignment.center,
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
    );
  }
}
