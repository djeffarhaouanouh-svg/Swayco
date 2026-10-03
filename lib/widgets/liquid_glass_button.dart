import 'dart:ui' show ImageFilter;

import 'package:cupertino_native_plus/cupertino_native_plus.dart' as cnp;
import 'package:flutter/material.dart';

import '../services/platform_glass.dart';
import '../theme/swayco_theme.dart';

/// A round glass button.
///
/// iOS 26+: Apple's own Liquid Glass — a native `UIButton` with the glass
/// effect, interactive (it swells and catches the light under the finger).
/// Everywhere else: the app's frosted glass (white .13, blur 14, white .22
/// rim), the same recipe as the nav bar.
///
/// The native path is a platform view: use it on STATIC chrome only (action
/// row, filter bubble). Inside the swiped card or next to the keyboard it
/// flickered — see commits 051f0fd and c4003fb.
class LiquidGlassButton extends StatefulWidget {
  const LiquidGlassButton({
    super.key,
    required this.icon,
    required this.sfSymbol,
    required this.onTap,
    this.size = 58,
    this.iconSize = 26,
    this.iconColor,
    this.semanticLabel,
  });

  /// Material icon for the Flutter glass.
  final IconData icon;

  /// SF Symbol name for the native glass (e.g. 'xmark', 'heart.fill').
  final String sfSymbol;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  /// Null = encre en clair, blanc en sombre ([SC.fg]).
  final Color? iconColor;
  final String? semanticLabel;

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    if (useNativeGlass) {
      return Semantics(
        button: true,
        label: widget.semanticLabel,
        child: SizedBox(
          width: s,
          height: s,
          child: cnp.CNButton.icon(
            icon: cnp.CNIcon.symbol(
              widget.sfSymbol,
              size: Size(widget.iconSize, widget.iconSize),
              color: widget.iconColor ?? SC.fg,
            ),
            onPressed: widget.onTap,
            theme: cnp.CNButtonTheme(iconColor: widget.iconColor ?? SC.fg),
            config: cnp.CNButtonConfig(
              style: cnp.CNButtonStyle.glass,
              width: s,
              minHeight: s,
              glassEffectInteractive: true,
            ),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  color: SC.fill.withValues(alpha: 0.13), boxShadow: SC.lift,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: SC.stroke.withValues(alpha: 0.22),
                    width: 1.2,
                  ),
                ),
                child: Icon(
                  widget.icon,
                  color: widget.iconColor ?? SC.fg,
                  size: widget.iconSize,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
