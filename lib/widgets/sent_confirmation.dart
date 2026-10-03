import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../services/swayco_sounds.dart';
import '../theme/swayco_theme.dart';

/// "Envoyé ✅" — the banking-app "transfer done" moment: the screen dims, a
/// green disc pops in, a white check draws itself, the label fades in, then
/// everything fades out on its own. Non-blocking: taps pass through.
void showSentConfirmation(BuildContext context, String label) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _SentConfirmation(
      label: label,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _SentConfirmation extends StatefulWidget {
  const _SentConfirmation({required this.label, required this.onDone});

  final String label;
  final VoidCallback onDone;

  @override
  State<_SentConfirmation> createState() => _SentConfirmationState();
}

class _SentConfirmationState extends State<_SentConfirmation>
    with SingleTickerProviderStateMixin {
  // 0 → 0.17 : dim + disc pops in; 0.14 → 0.36 : check draws;
  // 0.3 → 0.42 : label; hold; 0.83 → 1 : everything fades out.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  late final _disc = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.17, curve: Curves.easeOutBack),
  );
  late final _check = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.14, 0.36, curve: Curves.easeOutCubic),
  );
  late final _text = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.3, 0.42, curve: Curves.easeOut),
  );
  late final _fadeIn = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.12, curve: Curves.easeOut),
  );
  late final _fadeOut = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.83, 1, curve: Curves.easeIn),
  );

  bool _buzzed = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      // The little "tick" lands as the check finishes drawing.
      if (!_buzzed && _check.value >= 1) {
        _buzzed = true;
        if (!kIsWeb) HapticFeedback.mediumImpact();
        SwaycoSounds.play(SwSound.sentCheck);
      }
    });
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final opacity = _fadeIn.value * (1 - _fadeOut.value);
          return Opacity(
            opacity: opacity,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.55),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.scale(
                      scale: _disc.value,
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: SC.onlineDeep,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: SC.online.withValues(alpha: 0.45),
                              blurRadius: 28,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: CustomPaint(
                          painter: _CheckPainter(progress: _check.value),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Opacity(
                      opacity: _text.value,
                      child: Transform.translate(
                        offset: Offset(0, 8 * (1 - _text.value)),
                        child: Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A white check stroked from its short leg to the tip of its long one,
/// [progress] 0 → 1 revealing the path's length.
class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.28, h * 0.52)
      ..lineTo(w * 0.44, h * 0.67)
      ..lineTo(w * 0.73, h * 0.36);
    final metric = path.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * progress);
    canvas.drawPath(
      drawn,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.085
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
