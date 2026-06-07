import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';
import 'pressable.dart';

/// "Apple-glass" container — blur + low-alpha white tint + hairline border.
/// Use it for headers, the bottom nav, the chat composer, list cards.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.blur = 24,
    this.color,
    this.border,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color? color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? SC.glass,
            borderRadius: borderRadius,
            border: Border.all(color: border ?? SC.glassBorder, width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Round glass icon button — back arrow, phone, kebab, ...
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 20,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      bounce: true,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: SC.glassStrong,
              shape: BoxShape.circle,
              border: Border.all(color: SC.glassBorder),
            ),
            child: Icon(icon, color: iconColor ?? SC.textPrimary, size: iconSize),
          ),
        ),
      ),
    );
  }
}
