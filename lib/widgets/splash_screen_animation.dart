import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Boot splash for Swayco — renders the `assets/Traduction.json` Lottie
/// animation (cyan + white line-art) centred on pure black.
///
/// This is the in-app splash shown by `main.dart` while the app bootstraps.
/// The web boot page (`web/index.html`) plays the SAME Lottie immediately
/// during engine download, so the hand-off from the HTML splash to this one
/// is invisible.
///
/// The animation loops, so it works for any boot duration.
class SplashScreenAnimation extends StatelessWidget {
  const SplashScreenAnimation({
    super.key,
    this.asset = 'assets/Traduction.json',
    this.background = const Color(0xFF000000),
  });

  /// Lottie animation rendered at the centre of the screen.
  final String asset;

  /// Pure black by design — matches the web boot page and the app theme.
  final Color background;

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final size = math.min(shortest * 0.72, 460.0);

    return Scaffold(
      backgroundColor: background,
      body: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Lottie.asset(
            asset,
            repeat: true,
            fit: BoxFit.contain,
            // Smooth on web (CanvasKit) and native; keeps the line-art crisp.
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}
