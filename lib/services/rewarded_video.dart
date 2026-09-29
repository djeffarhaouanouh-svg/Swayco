import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_service.dart';
import 'revenue_cat.dart';

/// Google's test rewarded ad units — same test-by-default rule as
/// [AdService]: production ids are used only on a build made with
/// `--dart-define=ADMOB_PRODUCTION=true`.
const String _kTestRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
const String _kTestRewardedIOS = 'ca-app-pub-3940256099942544/1712485313';

/// Production rewarded units: NOT created in AdMob yet. Empty means
/// "unavailable" in a production build — never fall back to test ads there.
const String _kProdRewardedAndroid = '';
const String _kProdRewardedIOS = '';

/// Rewarded video ad — the "watch a video to reveal a like" unlock.
///
/// [isAvailable] is true only while a video is loaded and ready, so the Likes
/// sheet shows the real button instead of "coming soon". [show] returns true
/// only once the user actually earned the reward (watched to the end).
/// Best-effort like [AdService]: every failure is swallowed and logged.
abstract final class RewardedVideo {
  static RewardedAd? _ad;
  static bool _loading = false;

  static String? get _unitId {
    if (!AdService.isSupported) return null;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final id = AdService.useProduction
        ? (ios ? _kProdRewardedIOS : _kProdRewardedAndroid)
        : (ios ? _kTestRewardedIOS : _kTestRewardedAndroid);
    return id.isEmpty ? null : id;
  }

  static bool get isAvailable => _ad != null;

  /// Load one video in the background. Safe to call repeatedly; no-op for Pro
  /// viewers (they see every like already) and on unsupported platforms.
  static Future<void> preload() async {
    final unit = _unitId;
    if (unit == null || _loading || _ad != null) return;
    if (RevenueCat.proActive.value) return;
    _loading = true;
    try {
      await RewardedAd.load(
        adUnitId: unit,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _ad = ad;
            _loading = false;
          },
          onAdFailedToLoad: (error) {
            debugPrint('RewardedVideo: failed to load: $error');
            _ad = null;
            _loading = false;
          },
        ),
      );
    } catch (e) {
      debugPrint('RewardedVideo: preload threw: $e');
      _ad = null;
      _loading = false;
    }
  }

  /// Plays the loaded video. Resolves true if the reward was earned, false if
  /// nothing was ready, the ad failed to show, or the user closed it early.
  static Future<bool> show() async {
    final ad = _ad;
    if (ad == null) {
      unawaited(preload());
      return false;
    }
    _ad = null;
    final done = Completer<bool>();
    var earned = false;
    void finish() {
      if (!done.isCompleted) done.complete(earned);
      unawaited(preload());
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        finish();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('RewardedVideo: failed to show: $error');
        ad.dispose();
        finish();
      },
    );
    try {
      await ad.show(onUserEarnedReward: (_, _) => earned = true);
    } catch (e) {
      debugPrint('RewardedVideo: show threw: $e');
      ad.dispose();
      finish();
    }
    return done.future;
  }
}

/// Likers revealed by a rewarded video, one per video, remembered per account
/// on this device.
abstract final class LikesUnlocks {
  static String _key(String myId) => 'likes_unlocked_$myId';

  static Future<Set<String>> load(String myId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key(myId)) ?? const <String>[]).toSet();
  }

  static Future<void> add(String myId, String likerId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_key(myId)) ?? const <String>[]).toSet()
      ..add(likerId);
    await prefs.setStringList(_key(myId), ids.toList());
  }
}
