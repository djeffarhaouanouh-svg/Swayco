import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';
import 'swayco_wordmark.dart';

/// Boot splash for Swayco — coconut mark + `swaycø` centred on pure black.
///
/// Fades/scales in once, holds briefly, then fires [onComplete] so `main.dart`
/// can hand off to the first real screen. The web boot page (`web/index.html`)
/// shows the same mark during engine download so the hand-off stays seamless.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.background = const Color(0xFF000000),
    this.onComplete,
  });

  /// Pure black by design — matches the web boot page and the app theme.
  final Color background;

  /// Fired once after the entrance animation settles.
  final VoidCallback? onComplete;

  static const markAsset = SwaycoWordmark.asset;

  @override
  State<SplashScreenAnimation> createState() => _SplashScreenAnimationState();
}

class _SplashScreenAnimationState extends State<SplashScreenAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
    );
    _scale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOutCubic),
      ),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_completed) {
        _completed = true;
        Future<void>.delayed(const Duration(milliseconds: 450), () {
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
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final markSize = math.min(shortest * 0.32, 180.0);

    return Scaffold(
      backgroundColor: widget.background,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  SplashScreenAnimation.markAsset,
                  width: markSize,
                  height: markSize,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) =>
                      SizedBox(width: markSize, height: markSize),
                ),
                SizedBox(height: markSize * 0.16),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: 'swayc',
                        style: TextStyle(color: Colors.white),
                      ),
                      TextSpan(
                        text: 'ø',
                        style: TextStyle(color: SC.accent),
                      ),
                    ],
                  ),
                  style: TextStyle(
                    fontSize: math.min(shortest * 0.07, 34.0),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
