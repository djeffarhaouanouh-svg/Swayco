import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Boot splash for Swayco — plays `assets/splash.mp4` (Ring+Arrow, cassure
/// nette) centred on pure black.
///
/// Decorative only: `main.dart` dismisses this overlay as soon as the landing
/// screen is ready, even if the clip is still playing. The video itself plays
/// once (no loop) and holds its last frame if it finishes first. The web boot
/// page (`web/index.html`) plays the SAME file during engine download.
class SplashScreenAnimation extends StatefulWidget {
  const SplashScreenAnimation({
    super.key,
    this.asset = 'assets/splash.mp4',
    this.background = const Color(0xFF000000),
    this.onComplete,
  });

  /// Video rendered at the centre of the screen.
  final String asset;

  /// Pure black by design — matches the web boot page and the app theme.
  final Color background;

  /// Optional. Boot does **not** wait on this — the overlay is dismissed by
  /// `main.dart` when the landing screen is ready, even mid-playback.
  final VoidCallback? onComplete;

  @override
  State<SplashScreenAnimation> createState() => _SplashScreenAnimationState();
}

class _SplashScreenAnimationState extends State<SplashScreenAnimation> {
  VideoPlayerController? _controller;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    final controller = VideoPlayerController.asset(widget.asset);
    _controller = controller;
    controller.initialize().then((_) {
      if (!mounted) return;
      controller
        ..setLooping(false)
        ..setVolume(0)
        ..addListener(_onTick)
        ..play();
      setState(() {});
    }).catchError((Object e) {
      debugPrint('splash video failed to load: $e');
      _fireComplete();
    });
  }

  void _onTick() {
    final c = _controller;
    if (c == null || _completed) return;
    final v = c.value;
    if (v.isCompleted ||
        (v.duration > Duration.zero &&
            v.position >= v.duration &&
            !v.isPlaying)) {
      _fireComplete();
    }
  }

  void _fireComplete() {
    if (_completed) return;
    _completed = true;
    widget.onComplete?.call();
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.removeListener(_onTick);
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final size = math.min(shortest * 0.80, 500.0);
    final c = _controller;
    final ready = c != null && c.value.isInitialized;

    return Scaffold(
      backgroundColor: widget.background,
      body: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: ready
              ? FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: c.value.size.width,
                    height: c.value.size.height,
                    child: VideoPlayer(c),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
