import 'dart:async';

import 'package:flutter/material.dart';

/// Plays a gentle one-shot entrance the first time it's built: the child fades
/// in while sliding up a few px. Drop it around list items / sections so
/// content eases in instead of popping. Pass an increasing [delay] per item for
/// a staggered cascade.
///
/// The entrance only plays once per State, so on a `setState` rebuild it does
/// NOT replay (the State is reused). Give re-orderable list items stable keys so
/// their State — and thus "already entered" status — follows them.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 420),
    this.offset = 14,
  });

  final Widget child;

  /// Wait this long before starting — pass `index * step` for a cascade.
  final Duration delay;
  final Duration duration;

  /// How far (px) the child slides up into place.
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _delay = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - _t.value) * widget.offset),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Gently pulses its child's scale forever — a subtle "breathing" idle motion,
/// e.g. for empty-state icons so the screen feels alive instead of static.
class Breathing extends StatefulWidget {
  const Breathing({
    super.key,
    required this.child,
    this.minScale = 0.96,
    this.maxScale = 1.06,
    this.period = const Duration(milliseconds: 2600),
  });

  final Widget child;
  final double minScale;
  final double maxScale;
  final Duration period;

  @override
  State<Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<Breathing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat(reverse: true);
  late final Animation<double> _s = Tween<double>(
    begin: widget.minScale,
    end: widget.maxScale,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _s, child: widget.child);
  }
}
