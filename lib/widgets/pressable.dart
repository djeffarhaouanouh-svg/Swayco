import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'spring_press.dart';

/// Wraps a tappable child with an iOS-style "squish": it scales down while
/// held and fires a light haptic on tap. Drop-in around buttons, icons and
/// CTAs so every tap feels responsive. When [onTap] and [onLongPress] are both
/// null it renders the child inert (no scale, no haptic).
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.93,
    this.haptic = true,
    this.bounce = false,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// How far the child shrinks while pressed (1.0 = no shrink).
  final double scale;
  final bool haptic;

  /// When true, delegates to [SpringPress] for a real spring-physics bounce
  /// (compress then overshoot) — the same feel as the nav bar. When false, a
  /// plain ease-out squish.
  final bool bounce;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (mounted && _down != v) setState(() => _down = v);
  }

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  @override
  Widget build(BuildContext context) {
    // Bounce path → the shared spring-physics press (same as the nav bar),
    // so every bounce button across the app uses one identical spring.
    if (widget.bounce) {
      return SpringPress(
        onTap: widget.onTap,
        pressedScale: widget.scale,
        haptic: widget.haptic,
        behavior: widget.behavior,
        child: widget.child,
      );
    }
    // Plain squish (no overshoot) for callers that opt out of bounce.
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _enabled ? (_) => _set(true) : null,
      onTapUp: _enabled ? (_) => _set(false) : null,
      onTapCancel: _enabled ? () => _set(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
