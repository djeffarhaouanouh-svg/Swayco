import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/rewarded_video.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';
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

/// Bottom sheet on a blurred liker (direction 8c): go Pro (reveals all) or
/// watch a video (reveals this one). [onRevealed] fires once a video unlocked
/// [profile]. Même signature et même logique qu'avant.
Future<void> showLikesUnlockSheet(
  BuildContext context, {
  required String myId,
  required RemoteProfile? profile,
  required VoidCallback onRevealed,
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

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (ctx) => PopupSurface(
      sheet: true,
      washHeight: 150,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: PopupHandle()),
              const SizedBox(height: 6),
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SC.brandGradient,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: PopupTokens.surface,
                        ),
                        child: BlurredAvatar(profile: profile, size: 72),
                      ),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: SC.accent,
                          border: Border.all(
                            color: PopupTokens.surface,
                            width: 3,
                          ),
                        ),
                        child: const Icon(
                          Icons.lock_rounded,
                          size: 15,
                          color: SC.onAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              PopupTitle(AppStrings.t('likes_locked_title')),
              const SizedBox(height: 10),
              PopupBody(AppStrings.t('likes_locked_body')),
              const SizedBox(height: 22),
              PopupButton(
                label: AppStrings.t('likes_go_pro'),
                height: 54,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(showPaywallSheet(context));
                },
              ),
              const SizedBox(height: 8),
              PopupGhostButton(
                icon: Icons.play_circle_outline_rounded,
                height: 50,
                label: RewardedVideo.isAvailable
                    ? AppStrings.t('likes_watch_video')
                    : '${AppStrings.t('likes_watch_video')} · '
                        '${AppStrings.t('likes_video_soon')}',
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(watchVideo());
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

