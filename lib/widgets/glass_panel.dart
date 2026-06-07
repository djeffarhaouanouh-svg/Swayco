import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

import '../services/platform_glass.dart';
import 'glass.dart';

/// A single glass card SURFACE. On native (iPhone) it renders real shader
/// Liquid Glass; on web it falls back to the app's BackdropFilter
/// [GlassContainer] (web design unchanged).
///
/// Use for standalone cards / panels (chat list, language card, missions
/// card…). Shader glass is fine to use broadly — the only thing to avoid is
/// one *native platform view* per row inside a long scrolling list.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.padding,
    this.color,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  /// Tint of the glass (white-with-alpha). Drives both the shader glassColor
  /// and the BackdropFilter fallback fill.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (useShaderGlass) {
      return lg.GlassContainer(
        useOwnLayer: true,
        clipBehavior: Clip.antiAlias,
        padding: padding,
        shape: lg.LiquidRoundedSuperellipse(borderRadius: borderRadius),
        settings: lg.LiquidGlassSettings(
          blur: 8,
          thickness: 16,
          glassColor: color ?? const Color(0x14FFFFFF),
          refractiveIndex: 1.35,
        ),
        child: child,
      );
    }
    return GlassContainer(
      borderRadius: BorderRadius.circular(borderRadius),
      padding: padding,
      color: color,
      child: child,
    );
  }
}
