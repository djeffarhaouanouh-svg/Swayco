import 'package:flutter/material.dart';

import '../services/languages.dart';
import '../services/locations.dart';
import '../theme/swayco_theme.dart';
import 'swayco_seal.dart';

/// Code ISO du drapeau à poser sur la photo de quelqu'un : celui de son PAYS ;
/// à défaut de pays connu, celui de sa langue. Vide si rien ne s'applique.
String profileFlagIso({required String country, required String language}) {
  final iso = countryIso2For(country);
  if (iso.isNotEmpty) return iso;
  return findLanguageByCode(language)?.countryCode ?? '';
}

/// La couleur par défaut d'une personne sans photo, tirée de son prénom (la même
/// partout : avatars, mosaïque des groupes, bulles).
Color avatarFallbackColor(String name) =>
    ProfileAvatar._fallbackColor(name.trim().isEmpty ? '?' : name);

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
    this.showSeal = false,
    this.sealRingColor,
    this.flagIso = '',
    this.popular = false,
    this.gapColor,
  });

  /// Profil populaire (Pro / Plus) : un anneau jaune autour de la PHOTO seule,
  /// jamais autour de la bulle du pays. La taille totale ([size]) ne change pas.
  final bool popular;

  /// Couleur du fond de la ligne : le liseré entre l'anneau et la photo, et celui
  /// de la bulle du pays. Défaut : SC.bg.
  final Color? gapColor;

  /// Code ISO d'un pays (`jp`) : pose son drapeau rond, cerclé de blanc, sur le
  /// coin bas-droit de la photo. Il prend la place de la pastille [showSeal]
  /// (jamais les deux). Vide = pas de drapeau.
  final String flagIso;

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

  /// Pose la pastille ([SwaycoSeal]) sur la photo. Une grande photo (100 et
  /// plus) reçoit la capsule de verre, centrée sous elle ; une petite, la
  /// pastille seule sur son coin. Faux par défaut : rien ne change ailleurs.
  final bool showSeal;

  /// Couleur du fond de la ligne, pour le liseré de la petite pastille.
  final Color? sealRingColor;

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
    final ringW = popular ? size * 0.05 : 0.0;
    final gapW = popular ? size * 0.04 : 0.0;
    final photoD = size - 2 * (ringW + gapW);
    final bg = gapColor ?? SC.bg;
    final photo = Container(
      width: photoD,
      height: photoD,
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
              width: photoD,
              height: photoD,
              errorBuilder: (_, _, _) {
                // Primary failed → try the fallback once, else initials.
                if (_photoUrl == _primary &&
                    _fallback.isNotEmpty &&
                    _fallback != _primary) {
                  return Image.network(
                    _fallback,
                    fit: BoxFit.cover,
                    width: photoD,
                    height: photoD,
                    errorBuilder: (_, _, _) => _letterFallback(letterFontSize, photoD),
                  );
                }
                return _letterFallback(letterFontSize, photoD);
              },
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Container(
                  color: SC.menu,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: photoD * 0.4,
                    height: photoD * 0.4,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: SC.accentFg,
                    ),
                  ),
                );
              },
            )
          : _letterFallback(letterFontSize, photoD),
    );
    final Widget circle = !popular
        ? photo
        : Container(
            width: size,
            height: size,
            padding: EdgeInsets.all(gapW),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bg,
              border: Border.all(color: const Color(0xFFF4FF1F), width: ringW),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFF4FF1F).withValues(alpha: 0.16),
                  blurRadius: size * 0.16,
                ),
              ],
            ),
            child: photo,
          );

    // La pastille déborde de la photo (-12, -3) : le cercle rogne ses enfants,
    // donc elle vit dans une pile à part qui, elle, ne rogne pas.
    final flagD = popular ? size * 0.44 : (size * 0.42).clamp(18.0, 30.0);
    final Widget avatar = flagIso.isNotEmpty
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              circle,
              Positioned(
                right: popular ? -4 : -3,
                bottom: -3,
                child: Container(
                  width: flagD,
                  height: flagD,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: popular ? bg : Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: ClipOval(
                    child: Image.network(
                      'https://flagcdn.com/w80/${flagIso.toLowerCase()}.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const ColoredBox(color: Color(0xFFE5E7EB)),
                    ),
                  ),
                ),
              ),
            ],
          )
        : !showSeal
        ? circle
        : Stack(
            clipBehavior: Clip.none,
            children: [
              circle,
              if (size >= 100)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: -12,
                  child: Center(child: SwaycoSealCapsule()),
                )
              else
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: SwaycoSealCorner(ringColor: sealRingColor ?? SC.bg),
                ),
            ],
          );

    if (onTap == null) return avatar;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: avatar,
    );
  }

  Widget _letterFallback(double letterFontSize, double d) {
    return Container(
      width: d,
      height: d,
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
