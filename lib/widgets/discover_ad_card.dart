import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/ad_service.dart';
import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// A sponsored card dropped into the Discover deck every few cards: same
/// footprint and corner radius as a profile card, holding one medium-rectangle
/// AdMob banner, clearly labelled "Publicité", with a separate "Continuer"
/// button (kept well away from the ad so it can't be tapped by accident).
///
/// Never blocks the deck: if the banner hasn't loaded after a few seconds, or
/// fails, [onDone] fires by itself and the user just sees the next profile.
class DiscoverAdCard extends StatefulWidget {
  const DiscoverAdCard({super.key, required this.onDone});

  /// Called when the card should go away (Continuer tapped, or no ad to show).
  final VoidCallback onDone;

  @override
  State<DiscoverAdCard> createState() => _DiscoverAdCardState();
}

class _DiscoverAdCardState extends State<DiscoverAdCard> {
  static const _cardColor = Color(0xFF1A1A1D);
  static const _cardBorder = Color(0xFF2A2A2E);
  static const _loadTimeout = Duration(seconds: 6);

  BannerAd? _banner;
  bool _loaded = false;
  bool _gaveUp = false;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    final unit = AdService.bannerAdUnitId;
    if (unit == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _giveUp());
      return;
    }
    _banner = BannerAd(
      adUnitId: unit,
      size: AdSize.mediumRectangle,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          _timeout?.cancel();
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('DiscoverAdCard: banner failed to load: $error');
          ad.dispose();
          _banner = null;
          _giveUp();
        },
      ),
    )..load();
    _timeout = Timer(_loadTimeout, () {
      if (!_loaded) _giveUp();
    });
  }

  void _giveUp() {
    if (_gaveUp || !mounted) return;
    _gaveUp = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _banner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: _cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  AppStrings.t('ad_label'),
                  style: const TextStyle(
                    color: SC.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: banner != null && _loaded
                    ? SizedBox(
                        width: banner.size.width.toDouble(),
                        height: banner.size.height.toDouble(),
                        child: AdWidget(ad: banner),
                      )
                    : const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white24,
                        ),
                      ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: widget.onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.10),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  AppStrings.t('ad_continue'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
