import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/rewarded_video.dart';
import '../theme/swayco_theme.dart';
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
  const BlurredAvatar({super.key, required this.profile, required this.size});

  final RemoteProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
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

/// Bottom sheet on a blurred liker: go Pro (reveals all) or watch a video
/// (reveals this one). [onRevealed] fires once a video unlocked [profile].
Future<void> showLikesUnlockSheet(
  BuildContext context, {
  required String myId,
  required RemoteProfile? profile,
  required VoidCallback onRevealed,
}) {
  Future<void> watchVideo() async {
    if (!RewardedVideo.isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('likes_video_soon'))),
      );
      return;
    }
    final p = profile;
    if (p == null || !await RewardedVideo.show()) return;
    await LikesUnlocks.add(myId, p.id);
    onRevealed();
  }

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: SC.menu,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: BlurredAvatar(profile: profile, size: 72)),
            const SizedBox(height: 16),
            Text(
              AppStrings.t('likes_locked_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('likes_locked_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textMuted,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                unawaited(showPaywallSheet(context));
              },
              style: FilledButton.styleFrom(
                backgroundColor: SC.accent,
                foregroundColor: SC.bgDeep,
                minimumSize: const Size.fromHeight(50),
              ),
              child: Text(
                AppStrings.t('likes_go_pro'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                unawaited(watchVideo());
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: SC.textPrimary,
                side: const BorderSide(color: SC.glassBorderStrong),
                minimumSize: const Size.fromHeight(50),
              ),
              icon: const Icon(Icons.play_circle_outline_rounded),
              label: Text(
                RewardedVideo.isAvailable
                    ? AppStrings.t('likes_watch_video')
                    : '${AppStrings.t('likes_watch_video')} · '
                          '${AppStrings.t('likes_video_soon')}',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
