import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// When true, the release springs back with an elastic overshoot past 1.0
  /// (a little "pop"/bounce) instead of a plain ease-out.
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
        // Press = quick squish; release with [bounce] = springy overshoot.
        duration: _down || !widget.bounce
            ? const Duration(milliseconds: 110)
            : const Duration(milliseconds: 420),
        curve: _down || !widget.bounce ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}
