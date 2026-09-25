import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'revenue_cat.dart';

/// Set at build time to actually serve the real "Discover" interstitial.
/// Defaults to false (Google's own test ad unit) everywhere — a local
/// build, CI, and every TestFlight upload — so a production ad can never
/// fire before someone deliberately opts in on the one build meant to
/// really go live:
///   flutter build ... --dart-define=ADMOB_PRODUCTION=true
const bool _kAdsUseProduction = bool.fromEnvironment(
  'ADMOB_PRODUCTION',
  defaultValue: false,
);

/// Google's own test interstitial ad unit — always serves a placeholder
/// creative and never counts as a real impression.
/// https://developers.google.com/admob/flutter/test-ads
const String _kTestInterstitialAndroid =
    'ca-app-pub-3940256099942544/1033173712';
const String _kTestInterstitialIOS = 'ca-app-pub-3940256099942544/4411468910';

const String _kProdInterstitialAndroid =
    'ca-app-pub-1120860079267236/1603129738';
const String _kProdInterstitialIOS = 'ca-app-pub-1120860079267236/1890818620';

/// The "Discover" interstitial — a full-screen ad the Discover screen can
/// show at a moment of its own choosing. No such moment is wired up yet in
/// this first step: only the mechanism and the call point Discover needs
/// ([showDiscoverInterstitial]) exist so far.
///
/// Pro subscribers never see it — every show attempt checks
/// [RevenueCat.proActive] first. Loading and showing are both best-effort:
/// AdMob being down, misconfigured, or absent on this platform must never
/// affect Discover itself, so every failure is swallowed and logged, never
/// thrown.
abstract final class AdService {
  static InterstitialAd? _interstitial;
  static bool _loading = false;

  /// True only on a platform the native AdMob SDK supports (mirrors
  /// [RevenueCat.isSupported]'s own guard — no web ads).
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// True once an interstitial is loaded and ready to show.
  static bool get isReady => _interstitial != null;

  static String get _adUnitId {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _kAdsUseProduction ? _kProdInterstitialIOS : _kTestInterstitialIOS;
    }
    return _kAdsUseProduction
        ? _kProdInterstitialAndroid
        : _kTestInterstitialAndroid;
  }

  /// Fetch one interstitial in the background. Safe to call repeatedly — a
  /// load already in flight, an already-loaded ad, an unsupported platform,
  /// or a Pro viewer (no point loading an ad that will never show) all
  /// short-circuit.
  static Future<void> preload() async {
    if (!isSupported || _loading || _interstitial != null) return;
    if (RevenueCat.proActive.value) return;
    _loading = true;
    try {
      await InterstitialAd.load(
        adUnitId: _adUnitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            _interstitial = ad;
            _loading = false;
          },
          onAdFailedToLoad: (error) {
            debugPrint('AdService: interstitial failed to load: $error');
            _interstitial = null;
            _loading = false;
          },
        ),
      );
    } catch (e) {
      debugPrint('AdService: preload threw: $e');
      _interstitial = null;
      _loading = false;
    }
  }

  /// Shows the preloaded Discover interstitial and returns whether it
  /// actually displayed. Never shows to a Pro subscriber. Always preloads
  /// the next one right after this ad is dismissed or fails, so the next
  /// call has a fresh ad ready.
  static Future<bool> showDiscoverInterstitial() async {
    if (!isSupported || RevenueCat.proActive.value) return false;
    final ad = _interstitial;
    if (ad == null) {
      // Nothing ready — don't make the caller wait on a fresh load; just
      // start one for next time and report "no ad shown" now.
      unawaited(preload());
      return false;
    }
    _interstitial = null;
    final completer = Completer<bool>();
    void finish(bool shown) {
      if (!completer.isCompleted) completer.complete(shown);
      unawaited(preload());
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        finish(true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('AdService: interstitial failed to show: $error');
        ad.dispose();
        finish(false);
      },
    );
    try {
      await ad.show();
    } catch (e) {
      debugPrint('AdService: show threw: $e');
      ad.dispose();
      finish(false);
    }
    return completer.future;
  }
}
