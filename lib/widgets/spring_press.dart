import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Tappable wrapper with a REAL spring (physics) press bounce — the authentic
/// iOS "compress, then overshoot, then settle" feel, driven by a
/// [SpringSimulation] rather than a fixed curve. This is the same physics-based
/// approach native spring builders use; on a custom Flutter bar it's the way to
/// get the genuine "claque + rebond" instead of a flat ease-out.
///
/// On tap-down the child compresses to [pressedScale]; on release an
/// under-damped spring carries it back to 1.0 with a small overshoot.
/// Inert (no scale, no haptic) when [onTap] is null.
class SpringPress extends StatefulWidget {
  const SpringPress({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.85,
    this.popScale,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// How far the child compresses while held (1.0 = no compression).
  final double pressedScale;

  /// When set (> 1.0), the release plays a MARKED pop: the child grows past
  /// full size to this scale, then spring-settles back to 1.0 — a bigger, more
  /// visible bounce (like the nav bar's selection pop). Null → the plain
  /// compress-then-small-overshoot bounce.
  final double? popScale;
  final bool haptic;
  final HitTestBehavior behavior;

  @override
  State<SpringPress> createState() => _SpringPressState();
}

class _SpringPressState extends State<SpringPress>
    with SingleTickerProviderStateMixin {
  // Unbounded so the spring can overshoot past 1.0 (the "bounce").
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 1.0);

  // Under-damped spring: damping (20) < critical (2·√(mass·stiffness) = 40),
  // so it overshoots once then settles — the lively iOS pop.
  static const _spring = SpringDescription(mass: 1, stiffness: 400, damping: 20);

  bool get _enabled => widget.onTap != null;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) {
    _c.stop();
    _c.animateTo(
      widget.pressedScale,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  }

  void _springBack() {
    _c.animateWith(SpringSimulation(_spring, _c.value, 1.0, _c.velocity));
  }

  void _up(TapUpDetails _) {
    if (widget.haptic) HapticFeedback.lightImpact();
    final pop = widget.popScale;
    if (pop != null && pop > 1.0) {
      // Marked pop: grow past full size, then let the spring carry it home —
      // a clearly visible "claque + rebond" rather than a subtle overshoot.
      _c
          .animateTo(pop,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut)
          .whenComplete(() {
        if (mounted) _springBack();
      });
    } else {
      _springBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _enabled ? _down : null,
      onTapUp: _enabled ? _up : null,
      onTapCancel: _enabled ? _springBack : null,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Transform.scale(scale: _c.value, child: child),
        child: widget.child,
      ),
    );
  }
}
