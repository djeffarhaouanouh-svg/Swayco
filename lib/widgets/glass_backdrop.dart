import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/platform_glass.dart';

/// Native-only ambient backdrop: a dark gradient + a few heavily-blurred
/// colored blobs, so the Liquid Glass surfaces above have real material to
/// refract / blur. On a flat black background the glass effect is invisible —
/// this is what gives it relief.
///
/// On web it returns the previous solid dark background unchanged (the web
/// design is intentionally left as-is).
///
/// Tuning (see liquid-glass-task.md): if it reads too flat, raise [_blobBlur]
/// and [_blobAlpha] — that's the dial between "flat" and "glass".
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  static const double _blobBlur = 70;
  static const double _blobAlpha = 0.40;

  @override
  Widget build(BuildContext context) {
    if (!useShaderGlass) {
      // Web / unsupported: exactly the previous solid background.
      return ColoredBox(color: const Color(0xFF0E0E0E), child: child);
    }
    return Stack(
      children: [
        // Dark base gradient (navy → near-black).
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0A1024),
                  Color(0xFF080A12),
                  Color(0xFF0E0E0E),
                ],
              ),
            ),
          ),
        ),
        // Discreet colored blobs — blue / violet / cyan (the avatar palette),
        // pushed off the edges so only soft halos bleed in.
        const _Blob(
          color: Color(0xFF3B82F6),
          top: -70,
          left: -50,
          size: 260,
          blur: _blobBlur,
          alpha: _blobAlpha,
        ),
        const _Blob(
          color: Color(0xFF7C3AED),
          top: 70,
          right: -80,
          size: 280,
          blur: _blobBlur,
          alpha: _blobAlpha,
        ),
        const _Blob(
          color: Color(0xFF06B6D4),
          bottom: -60,
          right: 0,
          size: 240,
          blur: _blobBlur,
          alpha: _blobAlpha,
        ),
        child,
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({
    required this.color,
    required this.size,
    required this.blur,
    required this.alpha,
    this.top,
    this.left,
    this.right,
    this.bottom,
  });

  final Color color;
  final double size;
  final double blur;
  final double alpha;
  final double? top;
  final double? left;
  final double? right;
  final double? bottom;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: IgnorePointer(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: alpha),
            ),
          ),
        ),
      ),
    );
  }
}
