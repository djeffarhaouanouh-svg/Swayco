import 'package:cupertino_native_plus/cupertino_native_plus.dart' as cnp;
import 'package:flutter/material.dart';

import '../services/platform_glass.dart';

/// Apple's NATIVE Liquid Glass (platform view) on iOS 26+, REPLACING the
/// previous translucent fill (never layered on top). On web / older iOS /
/// Android it falls back to a translucent rounded fill so the surface stays
/// readable.
///
/// The native glass renders BEHIND [child] as an IgnorePointer overlay, so a
/// `TextField` inside [child] stays interactive. Use for STATIC surfaces
/// (composers, fields) — not one per row inside a ListView.builder.
class NativeGlass extends StatelessWidget {
  const NativeGlass({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.fallbackColor = const Color(0x80000000),
    this.fallbackBorder,
  });

  final Widget child;
  final double borderRadius;
  final Color fallbackColor;
  final Color? fallbackBorder;

  @override
  Widget build(BuildContext context) {
    if (useNativeGlass) {
      return cnp.LiquidGlassContainer(
        config: cnp.LiquidGlassConfig(
          shape: cnp.CNGlassEffectShape.rect,
          cornerRadius: borderRadius,
        ),
        child: child,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fallbackColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border:
            fallbackBorder == null ? null : Border.all(color: fallbackBorder!),
      ),
      child: child,
    );
  }
}
