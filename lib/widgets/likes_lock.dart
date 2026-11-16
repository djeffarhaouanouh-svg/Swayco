import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart' show showLikesProSheet;
import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/rewarded_video.dart';
import 'profile_avatar.dart';

/// Who may see the people who liked me: women always see everyone, free of
/// charge — the lock only ever applies to men. For a man, Pro (RevenueCat on
/// mobile, the Stripe tier on web) reveals everyone; a rewarded video reveals
/// one liker.
class LikesLock {
  LikesLock(
    this.myId, {
    required this.alwaysRevealed,
    required this.webPro,
    required this.unlocked,
  });

  final String myId;
  final bool alwaysRevealed;
  final bool webPro;
  final Set<String> unlocked;

  static Future<LikesLock> load(String myId) async {
    final results = await Future.wait<Object?>([
      ProfileApi.fetchById(myId),
      LikesUnlocks.load(myId),
    ]);
    final me = results[0] as RemoteProfile?;
    return LikesLock(
      myId,
      alwaysRevealed: me?.gender == 'f',
      webPro: me?.isPlus ?? false,
      unlocked: results[1] as Set<String>,
    );
  }

  bool isRevealed(String likerId) =>
      alwaysRevealed ||
      webPro ||
      RevenueCat.proActive.value ||
      unlocked.contains(likerId);
}

/// A liker's avatar, blurred just enough to hide who it is while still
/// letting the shape/colours show through — a teaser, not a solid smudge.
class BlurredAvatar extends StatelessWidget {
  const BlurredAvatar({
    super.key,
    required this.profile,
    required this.size,
    this.sigma = 4,
  });

  final RemoteProfile? profile;
  final double size;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: ProfileAvatar(
          displayName: '',
          avatarUrl: profile?.avatarUrl,
          fallbackUrl: profile?.fallbackPhotoUrl,
          size: size,
        ),
      ),
    );
  }
}

/// Lance la pub récompensée et, si elle va au bout, révèle [profile].
/// Pub indisponible : un message, rien n'est révélé.
Future<void> revealWithAd(
  BuildContext context, {
  required String myId,
  required RemoteProfile profile,
  required VoidCallback onRevealed,
}) async {
  unawaited(RewardedVideo.preload());
  if (!RewardedVideo.isAvailable) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('likes_video_soon'))),
    );
    return;
  }
  if (!await RewardedVideo.show()) return;
  Analytics.track('ad_watched', props: {'source': 'likes_unlock'});
  await LikesUnlocks.add(myId, profile.id);
  onRevealed();
}

/// La carte « Tout révéler avec Pro » : la feuille « Débloquer tous les
/// profils » — un abonnement Pro (révèle tout le monde) ou une pub, qui révèle
/// [profile] seulement ; [onRevealed] part une fois la pub vue jusqu'au bout.
Future<void> showLikesUnlockSheet(
  BuildContext context, {
  required String myId,
  required RemoteProfile? profile,
  required VoidCallback onRevealed,
  List<RemoteProfile?> likers = const [],
}) {
  unawaited(RewardedVideo.preload());
  return showLikesProSheet(
    context,
    likers: likers.isEmpty ? [profile] : likers,
    onWatchAd: () {
      final p = profile;
      if (p == null) return;
      unawaited(
        revealWithAd(context, myId: myId, profile: p, onRevealed: onRevealed),
      );
    },
  );
}
