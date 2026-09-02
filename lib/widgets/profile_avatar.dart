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
    this.fallbackUrl,
    this.size = 44,
    this.fontSize,
    this.onTap,
  });

  /// Public URL of the uploaded avatar. Null / empty → fall back to the
  /// colored-letter placeholder.
  final String? avatarUrl;

  /// Tried when [avatarUrl] fails to load (e.g. a stale PDP whose file was
  /// deleted) before dropping to the colored-letter placeholder.
  final String? fallbackUrl;
  final String displayName;
  final double size;
  final double? fontSize;
  final VoidCallback? onTap;

  /// No photo → a colour drawn from the name. The stored `avatar_color` is
  /// deliberately ignored: it had drifted to the same teal for most accounts,
  /// so every letter-avatar looked alike.
  Color get _bg => _fallbackColor(displayName.isEmpty ? '?' : displayName);

  String get _initial {
    final n = displayName.trim();
    if (n.isEmpty) return '?';
    return n.characters.first.toUpperCase();
  }

  String get _primary => avatarUrl?.trim() ?? '';
  String get _fallback => fallbackUrl?.trim() ?? '';

  /// The URL to show first: the dedicated avatar if set, otherwise the
  /// fallback (e.g. the Discover photo). A broken primary is caught at load
  /// time and retried with the fallback before dropping to initials.
  String? get _photoUrl {
    if (_primary.isNotEmpty) return _primary;
    if (_fallback.isNotEmpty) return _fallback;
    return null;
  }

  bool get _hasPhoto => _photoUrl != null;

  /// FNV-1a over the name — the old `hash * 31` collapsed half the names onto
  /// the same swatch (Lenny, Djeffar and Alice all came out yellow); FNV
  /// spreads them across the palette.
  static Color _fallbackColor(String seed) {
    const palette = <int>[
      0xFF00A884, 0xFF128C7E, 0xFF34B7F1, 0xFF1F6FEB, 0xFF7B61FF,
      0xFFA855F7, 0xFFEC4899, 0xFFF97316, 0xFFEAB308, 0xFF22C55E,
    ];
    if (seed.isEmpty) return Color(palette[0]);
    var hash = 0x811c9dc5;
    for (final c in seed.codeUnits) {
      hash = ((hash ^ c) * 0x01000193) & 0xFFFFFFFF;
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
              _photoUrl!,
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (_, _, _) {
                // Primary failed → try the fallback once, else initials.
                if (_photoUrl == _primary &&
                    _fallback.isNotEmpty &&
                    _fallback != _primary) {
                  return Image.network(
                    _fallback,
                    fit: BoxFit.cover,
                    width: size,
                    height: size,
                    errorBuilder: (_, _, _) => _letterFallback(letterFontSize),
                  );
                }
                return _letterFallback(letterFontSize);
              },
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Container(
                  color: SC.menu,
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
