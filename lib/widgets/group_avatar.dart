import 'package:flutter/material.dart';

import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';

/// La photo d'un groupe (handoff messages_groupes_quiz, A6) : automatique, une
/// mosaïque des photos de profil des 4 premiers membres. Pas de choix manuel.
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.members,
    this.size = 52,
    this.photoUrl = '',
  });

  /// Les profils des membres, dans l'ordre : seuls les 4 premiers comptent.
  final List<RemoteProfile> members;
  final double size;

  /// La photo choisie pour le groupe : si elle est là, elle remplace la
  /// mosaïque.
  final String photoUrl;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(4).toList();
    if (photoUrl.isNotEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: ClipOval(
          child: Image.network(
            photoUrl,
            fit: BoxFit.cover,
            // Photo morte : retour à la mosaïque.
            errorBuilder: (_, _, _) => GroupAvatar(members: members, size: size),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: ColoredBox(
          color: SC.menu,
          child: switch (shown.length) {
            0 => Icon(Icons.groups_rounded, color: SC.textMuted, size: size * 0.55),
            1 => _tile(shown[0]),
            2 => Row(children: [
                Expanded(child: _tile(shown[0])),
                const SizedBox(width: 1),
                Expanded(child: _tile(shown[1])),
              ]),
            3 => Row(children: [
                Expanded(child: _tile(shown[0])),
                const SizedBox(width: 1),
                Expanded(
                  child: Column(children: [
                    Expanded(child: _tile(shown[1])),
                    const SizedBox(height: 1),
                    Expanded(child: _tile(shown[2])),
                  ]),
                ),
              ]),
            _ => Column(children: [
                Expanded(
                  child: Row(children: [
                    Expanded(child: _tile(shown[0])),
                    const SizedBox(width: 1),
                    Expanded(child: _tile(shown[1])),
                  ]),
                ),
                const SizedBox(height: 1),
                Expanded(
                  child: Row(children: [
                    Expanded(child: _tile(shown[2])),
                    const SizedBox(width: 1),
                    Expanded(child: _tile(shown[3])),
                  ]),
                ),
              ]),
          },
        ),
      ),
    );
  }

  Widget _tile(RemoteProfile p) {
    final url = p.bestAvatarUrl;
    final initial = p.displayName.trim().isEmpty
        ? '?'
        : p.displayName.trim().characters.first.toUpperCase();
    final fallback = ColoredBox(
      color: SC.fg.withValues(alpha: 0.12),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: SC.textPrimary,
            fontSize: size * 0.28,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return Image.network(
      url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
