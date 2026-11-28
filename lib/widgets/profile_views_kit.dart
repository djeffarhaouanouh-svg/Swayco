import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'profile_avatar.dart';

/// Les couleurs communes à la carte « Vues du profil » et à son écran.
const Color kViewsYellow = Color(0xFFF4FF1F);
const Color kViewsInk = Color(0xFF04123A);

BoxDecoration viewsCardDecoration() {
  final light = SC.light;
  return BoxDecoration(
    color: light ? const Color(0xFFFFFFFF) : null,
    gradient: light
        ? null
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x24FFFFFF), Color(0x0FFFFFFF)],
          ),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(
      color: light ? const Color(0x1A04123A) : const Color(0x33FFFFFF),
    ),
  );
}

/// La photo ronde d'un visiteur. [blurred] (compte gratuit) : floutée, et sans
/// initiale qui trahirait le nom quand il n'y a pas de photo.
class VisitorFace extends StatelessWidget {
  const VisitorFace({
    super.key,
    required this.profile,
    required this.size,
    required this.blurred,
  });

  final RemoteProfile profile;
  final double size;
  final bool blurred;

  @override
  Widget build(BuildContext context) {
    final avatar = ProfileAvatar(
      displayName: blurred ? '' : profile.displayName,
      avatarUrl: profile.bestAvatarUrl,
      size: size,
    );
    if (!blurred) return avatar;
    final sigma = size / 7;
    return ClipOval(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
        child: avatar,
      ),
    );
  }
}
