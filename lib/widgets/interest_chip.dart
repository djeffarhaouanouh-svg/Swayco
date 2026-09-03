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
    this.compact = false,
    this.onTap,
  });

  /// Tighter pill — smaller text/padding/shadow. Used on the Discover card
  /// where the persona chip shares the frame with the name and location.
  final bool compact;

  /// Raw stored interest key (localised via [interestLabel] for display).
  final String label;
  final Color color;

  /// Whether this tag is currently picked (picker). Display chips stay true.
  /// Selection is shown with the check — colours stay fully opaque either way.
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
    final c = widget.compact;
    final fontSize = c ? 14.0 : 16.0;
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: const Cubic(0.2, 0.8, 0.3, 1.0),
      transform: Matrix4.translationValues(0, _pressed ? 2.0 : 0.0, 0),
      transformAlignment: Alignment.center,
      padding: EdgeInsets.symmetric(
        horizontal: c ? 14 : 18,
        vertical: c ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(c ? 10 : 13),
        boxShadow: [
          BoxShadow(
            color: lip,
            offset: Offset(0, c ? 3 : 5),
            blurRadius: 0,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: c ? 0.35 : 0.45),
            offset: Offset(0, c ? 6 : 10),
            blurRadius: c ? 12 : 20,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showCheck) ...[
            Icon(Icons.check_rounded, size: c ? 14 : 18, color: Colors.white),
            SizedBox(width: c ? 4 : 6),
          ],
          Text(
            interestLabel(widget.label),
            style: GoogleFonts.archivo(
              color: Colors.white,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.005 * fontSize,
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

    // Always full colour — selection is the leading check, not a grey veil.
    return Semantics(
      selected: widget.selected,
      button: _enabled,
      child: _enabled ? tappable : chip,
    );
  }
}
