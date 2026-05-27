import 'dart:math';

import 'package:flutter/material.dart';

/// One-shot particle burst that pops a handful of copies of an emoji
/// upward from a given screen position. Inserts itself into the
/// nearest [Overlay], plays its animation, then tears itself down —
/// no listener / state plumbing required at the call site.
///
/// Usage from a tap handler:
/// ```dart
/// final box = context.findRenderObject() as RenderBox?;
/// if (box != null) {
///   final pos = box.localToGlobal(box.size.center(Offset.zero));
///   EmojiBurst.show(context, position: pos, emoji: '🔥');
/// }
/// ```
abstract final class EmojiBurst {
  static const int _count = 8;
  static const Duration _duration = Duration(milliseconds: 900);

  /// Spawn the burst. Safe to call again before the previous burst
  /// completes — each call has its own OverlayEntry.
  static void show(
    BuildContext context, {
    required Offset position,
    required String emoji,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _EmojiBurstLayer(
        origin: position,
        emoji: emoji,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  static List<_BurstParticle> _particles(String emoji) {
    final rnd = Random();
    return List<_BurstParticle>.generate(_count, (i) {
      // Spread the angle around straight up (-π/2), with random
      // horizontal jitter. Outer particles get a wider angle so the
      // burst opens up like a small fan.
      final angle = -pi / 2 + (rnd.nextDouble() - 0.5) * (pi * 0.85);
      final distance = 60 + rnd.nextDouble() * 60; // px
      final dx = cos(angle) * distance;
      final dy = sin(angle) * distance;
      // Small per-particle delay so they don't all peak at once.
      final delay = rnd.nextDouble() * 0.20;
      final startScale = 0.7 + rnd.nextDouble() * 0.4;
      final endScale = startScale + 0.4;
      return _BurstParticle(
        emoji: emoji,
        dx: dx,
        dy: dy,
        delay: delay,
        startScale: startScale,
        endScale: endScale,
        rotation: (rnd.nextDouble() - 0.5) * 0.6,
      );
    });
  }
}

class _BurstParticle {
  const _BurstParticle({
    required this.emoji,
    required this.dx,
    required this.dy,
    required this.delay,
    required this.startScale,
    required this.endScale,
    required this.rotation,
  });
  final String emoji;
  final double dx;
  final double dy;
  /// 0..1 fraction of the total burst duration to wait before this
  /// particle starts moving.
  final double delay;
  final double startScale;
  final double endScale;
  /// Radians applied as a final rotation at the end of the flight,
  /// gives the burst a bit of organic spin.
  final double rotation;
}

class _EmojiBurstLayer extends StatefulWidget {
  const _EmojiBurstLayer({
    required this.origin,
    required this.emoji,
    required this.onDone,
  });

  final Offset origin;
  final String emoji;
  final VoidCallback onDone;

  @override
  State<_EmojiBurstLayer> createState() => _EmojiBurstLayerState();
}

class _EmojiBurstLayerState extends State<_EmojiBurstLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_BurstParticle> _particles;

  @override
  void initState() {
    super.initState();
    _particles = EmojiBurst._particles(widget.emoji);
    _ctrl = AnimationController(
      vsync: this,
      duration: EmojiBurst._duration,
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final t = _ctrl.value;
          return Stack(
            children: [
              for (final p in _particles) _buildParticle(p, t),
            ],
          );
        },
      ),
    );
  }

  Widget _buildParticle(_BurstParticle p, double globalT) {
    // Re-normalise t so each particle has its own [delay, 1] window.
    final local = ((globalT - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
    if (local <= 0) {
      return Positioned(
        left: widget.origin.dx,
        top: widget.origin.dy,
        child: const SizedBox.shrink(),
      );
    }
    // Ease the position outward; opacity fades over the last third.
    final eased = Curves.easeOut.transform(local);
    final dx = p.dx * eased;
    final dy = p.dy * eased - (local * local * 30); // extra arc lift
    final scale = p.startScale + (p.endScale - p.startScale) * eased;
    // Quick fade-in over the first ~12% so a particle doesn't pop into
    // existence at full opacity; then long fade-out over the tail.
    final fadeIn = (local / 0.12).clamp(0.0, 1.0);
    final fadeOut = 1.0 - ((local - 0.55) / 0.45).clamp(0.0, 1.0);
    final opacity = (fadeIn * fadeOut).clamp(0.0, 1.0);
    return Positioned(
      // The text glyph is positioned by its top-left; offset by half a
      // square so the emoji's centre sits at the burst origin.
      left: widget.origin.dx + dx - 14,
      top: widget.origin.dy + dy - 14,
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: p.rotation * eased,
          child: Transform.scale(
            scale: scale,
            child: Text(
              p.emoji,
              style: const TextStyle(fontSize: 28),
            ),
          ),
        ),
      ),
    );
  }
}
