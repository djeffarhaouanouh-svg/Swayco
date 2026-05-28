import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Reusable circular avatar: shows the network photo when [avatarUrl] is
/// provided, falls back to the first letter of [displayName] on a colored
/// background otherwise. Used by every screen that renders a user (chat
/// list, profile header, search results, friend list, thread header, etc.).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.displayName,
    this.avatarUrl,
    this.avatarColorHex,
    this.size = 44,
    this.fontSize,
    this.onTap,
  });

  /// Public URL of the uploaded avatar. Null / empty → fall back to the
  /// colored-letter placeholder.
  final String? avatarUrl;
  final String displayName;
  final String? avatarColorHex;
  final double size;
  final double? fontSize;
  final VoidCallback? onTap;

  Color get _bg {
    final hex = avatarColorHex;
    if (hex != null && hex.isNotEmpty) {
      final parsed = _parseHex(hex);
      if (parsed != null) return parsed;
    }
    return _fallbackColor(displayName.isEmpty ? '?' : displayName);
  }

  String get _initial {
    final n = displayName.trim();
    if (n.isEmpty) return '?';
    return n.characters.first.toUpperCase();
  }

  bool get _hasPhoto => avatarUrl != null && avatarUrl!.trim().isNotEmpty;

  static Color? _parseHex(String hex) {
    var v = hex.trim();
    if (v.isEmpty) return null;
    if (v.startsWith('#')) v = v.substring(1);
    if (v.length == 6) v = 'FF$v';
    if (v.length != 8) return null;
    final n = int.tryParse(v, radix: 16);
    return n == null ? null : Color(n);
  }

  static Color _fallbackColor(String seed) {
    const palette = <int>[
      0xFF00A884, 0xFF128C7E, 0xFF34B7F1, 0xFF1F6FEB, 0xFF7B61FF,
      0xFFA855F7, 0xFFEC4899, 0xFFF97316, 0xFFEAB308, 0xFF22C55E,
    ];
    if (seed.isEmpty) return Color(palette[0]);
    var hash = 0;
    for (final c in seed.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    return Color(palette[hash % palette.length]);
  }

  @override
  Widget build(BuildContext context) {
    final letterFontSize = fontSize ?? size * 0.42;
    final circle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _hasPhoto ? Colors.transparent : _bg,
      ),
      child: _hasPhoto
          ? Image.network(
              avatarUrl!,
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (_, _, _) => _letterFallback(letterFontSize),
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Container(
                  color: SC.bubbleIn,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: size * 0.4,
                    height: size * 0.4,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: SC.accent,
                    ),
                  ),
                );
              },
            )
          : _letterFallback(letterFontSize),
    );

    if (onTap == null) return circle;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: circle,
    );
  }

  Widget _letterFallback(double letterFontSize) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _bg),
      child: Text(
        _initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: letterFontSize,
        ),
      ),
    );
  }
}
