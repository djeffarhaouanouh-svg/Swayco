import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/interests.dart';

/// Interest tag pill — Style "Relief 3D" (design handoff).
///
/// Solid palette colour, Archivo Black, 13px radius, hard bottom lip + soft
/// drop shadow. Presses sink the chip by 2px (hover equivalent on touch).
class InterestTagChip extends StatefulWidget {
  const InterestTagChip({
    super.key,
    required this.label,
    required this.color,
    this.selected = true,
    this.showCheck = false,
    this.onTap,
  });

  /// Raw stored interest key (localised via [interestLabel] for display).
  final String label;
  final Color color;

  /// Filled/active vs dimmed (picker: unpicked options).
  final bool selected;

  /// Leading check — picker only, for already-picked options.
  final bool showCheck;
  final VoidCallback? onTap;

  @override
  State<InterestTagChip> createState() => _InterestTagChipState();
}

class _InterestTagChipState extends State<InterestTagChip> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (!_enabled) return;
    if (mounted && _pressed != v) setState(() => _pressed = v);
  }

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final lip = interestDarken(widget.color, 0.38);
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: const Cubic(0.2, 0.8, 0.3, 1.0),
      transform: Matrix4.translationValues(0, _pressed ? 2.0 : 0.0, 0),
      transformAlignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: lip,
            offset: const Offset(0, 5),
            blurRadius: 0,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            offset: const Offset(0, 10),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showCheck) ...[
            const Icon(Icons.check_rounded, size: 18, color: Colors.white),
            const SizedBox(width: 6),
          ],
          Text(
            interestLabel(widget.label),
            style: GoogleFonts.archivo(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.005 * 16,
              height: 1.0,
            ),
          ),
        ],
      ),
    );

    final tappable = GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      behavior: HitTestBehavior.opaque,
      child: chip,
    );

    // Unpicked picker options: same relief, reduced opacity (handoff).
    return Opacity(
      opacity: widget.selected ? 1.0 : 0.42,
      child: _enabled ? tappable : chip,
    );
  }
}
