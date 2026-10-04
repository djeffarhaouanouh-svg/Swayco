import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
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

/// Tap on a blurred liker → the Likes paywall ("1b", full screen): the wall
/// of [likers] (blurred) with their count, go Pro (reveals all) or watch a
/// video (reveals [profile]). [onRevealed] fires once a video unlocked it.
Future<void> showLikesUnlockSheet(
  BuildContext context, {
  required String myId,
  required RemoteProfile? profile,
  required VoidCallback onRevealed,
  List<RemoteProfile?> likers = const [],
}) {
  unawaited(RewardedVideo.preload());
  Future<void> watchVideo() async {
    if (!RewardedVideo.isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('likes_video_soon'))),
      );
      return;
    }
    final p = profile;
    if (p == null || !await RewardedVideo.show()) return;
    Analytics.track('ad_watched', props: {'source': 'likes_unlock'});
    await LikesUnlocks.add(myId, p.id);
    onRevealed();
  }

  return showLikesWallPaywall(
    context,
    likers: likers.isEmpty ? [profile] : likers,
    videoAvailable: RewardedVideo.isAvailable,
    onWatchVideo: () => unawaited(watchVideo()),
    profile: profile,
  );
}
