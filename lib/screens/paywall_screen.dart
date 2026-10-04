import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_strings.dart';
import '../services/swayco_sounds.dart';
import '../services/device_id.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/stripe_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/fade_scale_route.dart';
import '../widgets/popup_kit.dart';
import '../widgets/profile_avatar.dart';

/// The subscription paywall ("1c", direction 8c): a preview of MY card as a
/// Pro, with a Free / Pro switch. Full screen, slides up; pops when closed or
/// once the purchase went through. Call from anywhere (settings, Discover…).
Future<void> showPaywallSheet(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const _ProPreviewPaywall(),
    ),
  );
}

/// The Boost offer, same family as 1c: my card highlighted and "BOOSTÉ",
/// 24 h at the top of Discover, one-time purchase. [onPurchased] runs once
/// the store confirmed (the webhook credits the Boost a few seconds later).
Future<void> showBoostPaywall(
  BuildContext context, {
  required Future<void> Function() onPurchased,
}) {
  return Navigator.of(context).push<void>(
    // Apparaît sur place, sans monter du bas.
    fadeScaleRoute<void>((_) => _BoostPaywall(onPurchased: onPurchased)),
  );
}

/// The Likes-page paywall ("1b"): a wall of the blurred likers, go Pro or
/// watch a video to reveal one. [onWatchVideo] runs after this screen closed.
Future<void> showLikesWallPaywall(
  BuildContext context, {
  required List<RemoteProfile?> likers,
  required bool videoAvailable,
  required VoidCallback onWatchVideo,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _LikesWallPaywall(
        likers: likers,
        videoAvailable: videoAvailable,
        onWatchVideo: onWatchVideo,
      ),
    ),
  );
}

// ══════════════════════════════════════════════════════════════════════════
// Shared purchase logic — identical for both paywalls.
// ══════════════════════════════════════════════════════════════════════════

mixin _PaywallPurchase<T extends StatefulWidget> on State<T> {
  /// Backend tier the web Stripe checkout sells for the Pro plan.
  static const String _stripeTier = 'plus';

  bool _busy = false;

  /// Store-localized price from RevenueCat ("6,99 €"). Null while loading,
  /// on web (Stripe shows its own price) or when the package can't load.
  String? _price;

  void _loadPrice() {
    if (!RevenueCat.isSupported) return;
    RevenueCat.priceOf(RevenueCat.proPackageId).then((p) {
      if (mounted) setState(() => _price = p);
    });
  }

  Future<void> _subscribe() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // iOS/Android → always the native store (Stripe is forbidden there,
      // even if RevenueCat failed to configure). Web/desktop → Stripe.
      if (RevenueCat.isSupported) {
        await _subscribeViaStore();
      } else {
        await _subscribeViaStripe();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _subscribeViaStore() async {
    final outcome = await RevenueCat.purchasePackage(
      packageId: RevenueCat.proPackageId,
      entitlementId: RevenueCat.proEntitlementId,
    );
    if (!mounted) return;
    if (outcome == PurchaseOutcome.success) {
      HapticFeedback.heavyImpact();
      SwaycoSounds.play(SwSound.purchase);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('paywall_snack_activated'))),
      );
      Navigator.of(context).maybePop();
    } else if (outcome == PurchaseOutcome.unavailable) {
      final why = RevenueCat.lastUnavailableReason;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            why.isEmpty
                ? AppStrings.t('paywall_snack_unavailable')
                : '${AppStrings.t('paywall_snack_unavailable')}\n($why)',
          ),
        ),
      );
    } else if (outcome == PurchaseOutcome.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('paywall_snack_error'))),
      );
    }
    // PurchaseOutcome.cancelled → the user backed out; say nothing.
  }

  Future<void> _subscribeViaStripe() async {
    final url = await StripeApi.startCheckout(_stripeTier);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('paywall_snack_checkout_error'))),
      );
      return;
    }
    await launchUrl(
      Uri.parse(url),
      webOnlyWindowName: '_self',
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _openExternal(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(url)));
    }
  }

  /// Mobile → RevenueCat restore. Web → the Stripe customer portal.
  Future<void> _restore() async {
    if (RevenueCat.isSupported) {
      setState(() => _busy = true);
      final active = await RevenueCat.restoreEntitlements();
      if (!mounted) return;
      setState(() => _busy = false);
      if (active.contains(RevenueCat.proEntitlementId)) {
        HapticFeedback.heavyImpact();
        SwaycoSounds.play(SwSound.purchase);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('paywall_snack_restored'))),
        );
        Navigator.of(context).maybePop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('paywall_snack_nothing_restore'))),
        );
      }
      return;
    }
    final url = await StripeApi.openPortal();
    if (!mounted) return;
    if (url != null && url.isNotEmpty) {
      await _openExternal(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('paywall_snack_nothing_restore'))),
      );
    }
  }

  /// Where the charge lands, per platform — Apple's auto-renewal
  /// disclosure must name the billing account on the paywall itself.
  String _accountPhrase() {
    if (kIsWeb) return AppStrings.t('paywall_account_web');
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return AppStrings.t('paywall_account_apple');
      case TargetPlatform.android:
        return AppStrings.t('paywall_account_google');
      default:
        return AppStrings.t('paywall_account_other');
    }
  }

  /// Auto-renewable subscription disclosure required by App Store Guideline
  /// 3.1.2(c) — kept on both paywalls even though the mock-ups omit it.
  Widget _legalDisclosure() {
    final price = _price;
    final tiers = price == null
        ? 'Pro'
        : 'Pro $price${AppStrings.t('paywall_period_month')}';
    return Text(
      AppStrings.t(
        'paywall_legal',
        args: {'tiers': tiers, 'account': _accountPhrase()},
      ),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.4),
        fontSize: 10,
        height: 1.35,
      ),
    );
  }

  /// "Restaurer · Conditions · Confidentialité" on ONE line.
  Widget _footer() {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FooterLink(AppStrings.t('paywall_restore'), _restore),
          const _FooterDot(),
          _FooterLink(
            AppStrings.t('paywall_terms'),
            () => _openExternal('https://www.swayco.fr/terms'),
          ),
          const _FooterDot(),
          _FooterLink(
            AppStrings.t('paywall_privacy'),
            () => _openExternal('https://www.swayco.fr/privacy'),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 1c — Preview of my card as a Pro
// ══════════════════════════════════════════════════════════════════════════

class _ProPreviewPaywall extends StatefulWidget {
  const _ProPreviewPaywall();

  @override
  State<_ProPreviewPaywall> createState() => _ProPreviewPaywallState();
}

class _ProPreviewPaywallState extends State<_ProPreviewPaywall>
    with _PaywallPurchase {
  bool _pro = true;
  RemoteProfile? _me;

  @override
  void initState() {
    super.initState();
    _loadPrice();
    _loadMe();
  }

  Future<void> _loadMe() async {
    try {
      final id = await DeviceId.getOrCreate();
      final me = await ProfileApi.fetchById(id);
      if (mounted) setState(() => _me = me);
    } catch (_) {
      // The card falls back to its placeholder — nothing else depends on it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final price = _price;
    final ctaSub = price == null
        ? AppStrings.t('pw_cancel_anytime')
        : '$price${AppStrings.t('paywall_period_month')} · '
            '${AppStrings.t('pw_cancel_anytime')}';
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: SC.dBg,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1A2040), Color(0xFF10121C), SC.dBg],
              stops: [0, 0.45, 1],
            ),
          ),
          child: Stack(
            children: [
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 380,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.topCenter,
                      radius: 1.2,
                      colors: [
                        Color(0x8C2B7FFF),
                        Color(0x1F18DDEA),
                        Color(0x001F5EFF),
                      ],
                      stops: [0, 0.45, 0.75],
                    ),
                  ),
                ),
              ),
              SafeArea(
                bottom: false,
                child: _ScrollFill(
                  padding: EdgeInsets.fromLTRB(22, 12, 22, safe.bottom + 14),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 44,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              // Colle a l'angle (14 / 6), comme les boutons du profil.
                              child: Transform.translate(
                                offset: const Offset(-8, -6),
                                child: _CloseButton(
                                  onTap: () => Navigator.of(context).maybePop(),
                                ),
                              ),
                            ),
                            _FreeProSwitch(
                              pro: _pro,
                              onChanged: (v) => setState(() => _pro = v),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      _PreviewCard(
                        me: _me,
                        highlighted: _pro,
                        badge: _pro
                            ? AppStrings.t('paywall_popular').toUpperCase()
                            : null,
                      ),
                      const SizedBox(height: 28),
                      _HighlightTitle(
                        head: AppStrings.t('pw_preview_title'),
                        tail: AppStrings.t(
                          _pro ? 'pw_preview_tail_pro' : 'pw_preview_tail_free',
                        ),
                        fontSize: 26,
                        tailBg: _pro
                            ? SC.accent
                            : Colors.white.withValues(alpha: 0.14),
                        tailFg: _pro ? SC.onAccent : SC.dTextPrimary,
                      ),
                      const SizedBox(height: 16),
                      // Les arguments : le badge Populaire d'abord.
                      _PerkGrid(
                        on: _pro,
                        labels: [
                          AppStrings.t('pw_arg_badge'),
                          AppStrings.t('pw_arg_likes'),
                          AppStrings.t('pw_arg_visibility'),
                          AppStrings.t('pw_arg_special'),
                        ],
                      ),
                      const Spacer(),
                      const SizedBox(height: 22),
                      _TwoLineCta(
                        title: AppStrings.t('pw_activate'),
                        subtitle: ctaSub,
                        busy: _busy,
                        onPressed: _subscribe,
                      ),
                      const SizedBox(height: 10),
                      _legalDisclosure(),
                      const SizedBox(height: 10),
                      _footer(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Glass pill with the two options; the active one is yellow.
class _FreeProSwitch extends StatelessWidget {
  const _FreeProSwitch({required this.pro, required this.onChanged});

  final bool pro;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(String label, bool active, VoidCallback onTap) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: active ? SC.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active
                  ? SC.onAccent
                  : SC.dTextPrimary.withValues(alpha: 0.6),
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          option(AppStrings.t('pw_free'), !pro, () => onChanged(false)),
          option('Pro', pro, () => onChanged(true)),
        ],
      ),
    );
  }
}

/// My Discover card, tilted −3°: the real photo, "Toi, 24", city · language.
/// [highlighted] = brand-gradient frame + blue glow; [badge] = yellow pill
/// top-left ("POPULAIRE" for Pro, "BOOSTÉ" for a Boost).
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.me,
    required this.highlighted,
    this.badge,
  });

  final RemoteProfile? me;
  final bool highlighted;
  final String? badge;

  String get _photo {
    final p = me;
    if (p == null) return '';
    for (final u in p.photos) {
      if (u.isNotEmpty) return u;
    }
    if (p.discoverPhotoUrl.isNotEmpty) return p.discoverPhotoUrl;
    return p.avatarUrl;
  }

  @override
  Widget build(BuildContext context) {
    final p = me;
    final you = AppStrings.t('pw_you');
    final title = p?.age != null ? '$you, ${p!.age}' : you;
    final place = [
      if (p != null && p.city.trim().isNotEmpty)
        p.city.trim()
      else if (p != null && p.country.trim().isNotEmpty)
        p.country.trim(),
      if (p != null && p.language.trim().isNotEmpty)
        p.language.trim().toUpperCase(),
    ].join(' · ');
    final photo = _photo;
    return Transform.rotate(
      angle: -3 * math.pi / 180,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 224,
        height: 300,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: highlighted ? SC.brandGradient : null,
          boxShadow: highlighted
              ? [
                  BoxShadow(
                    color: SC.brandBlue.withValues(alpha: 0.8),
                    blurRadius: 50,
                    spreadRadius: -8,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(27),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF26262A)),
              if (photo.isNotEmpty)
                Image.network(
                  photo,
                  fit: BoxFit.cover,
                  alignment: const Alignment(0, -0.4),
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (p != null)
                Center(
                  child: ProfileAvatar(
                    displayName: p.displayName,
                    avatarUrl: null,
                    size: 96,
                    fontSize: 40,
                  ),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xCC000000)],
                    stops: [0.5, 1],
                  ),
                ),
              ),
              if (badge case final b?)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: SC.accent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      b,
                      style: const TextStyle(
                        color: SC.onAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: popupDisplay(
                        fontSize: 22,
                        letterSpacing: -0.6,
                        color: Colors.white,
                      ),
                    ),
                    if (place.isNotEmpty)
                      Text(
                        place,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One perk line: gradient disc + icon, the perk, its value on the right.
class _PerkRow extends StatelessWidget {
  const _PerkRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.on,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool on;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [SC.brandBlueDeep, SC.brandCyan],
              ),
            ),
            child: Icon(icon, size: 17, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: SC.dTextPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: on ? SC.accent : SC.dTextPrimary.withValues(alpha: 0.55),
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// Yellow pill, 64 high: "Activer Pro" over "6,99 €/mois · résiliable…".
class _TwoLineCta extends StatelessWidget {
  const _TwoLineCta({
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.onPressed,
  });

  final String title;
  final String subtitle;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      width: double.infinity,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: SC.accent,
          foregroundColor: SC.onAccent,
          disabledBackgroundColor: SC.accent.withValues(alpha: 0.6),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
        child: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: SC.onAccent,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: popupDisplay(fontSize: 15, color: SC.onAccent),
                  ),
                  const SizedBox(height: 1),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      style: const TextStyle(
                        color: SC.onAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Boost — same family as 1c, one-time purchase
// ══════════════════════════════════════════════════════════════════════════

class _BoostPaywall extends StatefulWidget {
  const _BoostPaywall({required this.onPurchased});

  final Future<void> Function() onPurchased;

  @override
  State<_BoostPaywall> createState() => _BoostPaywallState();
}

class _BoostPaywallState extends State<_BoostPaywall> {
  bool _busy = false;
  String? _price;
  RemoteProfile? _me;

  @override
  void initState() {
    super.initState();
    if (RevenueCat.isSupported) {
      RevenueCat.priceOf(RevenueCat.boostPackageId).then((p) {
        if (mounted) setState(() => _price = p);
      });
    }
    _loadMe();
  }

  Future<void> _loadMe() async {
    try {
      final id = await DeviceId.getOrCreate();
      final me = await ProfileApi.fetchById(id);
      if (mounted) setState(() => _me = me);
    } catch (_) {
      // The card falls back to its placeholder — nothing else depends on it.
    }
  }

  Future<void> _buy() async {
    if (_busy) return;
    setState(() => _busy = true);
    final outcome = await RevenueCat.purchaseConsumable(
      RevenueCat.boostPackageId,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    final key = switch (outcome) {
      PurchaseOutcome.success => 'boost_snack_success',
      PurchaseOutcome.unavailable => 'paywall_snack_unavailable',
      PurchaseOutcome.error => 'paywall_snack_error',
      PurchaseOutcome.cancelled => null,
    };
    final messenger = ScaffoldMessenger.of(context);
    if (key != null) {
      final why = outcome == PurchaseOutcome.unavailable
          ? RevenueCat.lastUnavailableReason
          : '';
      messenger.showSnackBar(
        SnackBar(
          duration: Duration(seconds: why.isEmpty ? 4 : 8),
          content: Text(
            why.isEmpty ? AppStrings.t(key) : '${AppStrings.t(key)}\n($why)',
          ),
        ),
      );
    }
    if (outcome == PurchaseOutcome.success) {
      HapticFeedback.heavyImpact();
      SwaycoSounds.play(SwSound.boost);
      Navigator.of(context).maybePop();
      await widget.onPurchased();
    }
  }

  Future<void> _openExternal(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(url)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final price = _price;
    final ctaSub = price == null
        ? AppStrings.t('boost_pw_one_time')
        : '$price · ${AppStrings.t('boost_pw_one_time')}';
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: SC.dBg,
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1A2040), Color(0xFF10121C), SC.dBg],
              stops: [0, 0.45, 1],
            ),
          ),
          child: Stack(
            children: [
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 380,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.topCenter,
                      radius: 1.2,
                      colors: [
                        Color(0x8C2B7FFF),
                        Color(0x1F18DDEA),
                        Color(0x001F5EFF),
                      ],
                      stops: [0, 0.45, 0.75],
                    ),
                  ),
                ),
              ),
              SafeArea(
                bottom: false,
                child: _ScrollFill(
                  padding: EdgeInsets.fromLTRB(22, 12, 22, safe.bottom + 14),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 44,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Transform.translate(
                            offset: const Offset(-8, -6),
                            child: _CloseButton(
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      _PreviewCard(
                        me: _me,
                        highlighted: true,
                        badge: AppStrings.t('boost_pw_badge'),
                      ),
                      const SizedBox(height: 28),
                      _HighlightTitle(
                        head: AppStrings.t('boost_pw_title_head'),
                        tail: AppStrings.t('boost_pw_title_tail'),
                        fontSize: 26,
                        tailBg: SC.accent,
                        tailFg: SC.onAccent,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        AppStrings.t('boost_pw_sub'),
                        textAlign: TextAlign.center,
                        style: SCText.subtitle.copyWith(
                          fontSize: 14.5,
                          height: 1.5,
                          color: SC.dTextPrimary.withValues(alpha: 0.75),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _PerkRow(
                        icon: Icons.rocket_launch_rounded,
                        label: AppStrings.t('boost_pw_row_place'),
                        value: AppStrings.t('boost_pw_row_place_value'),
                        on: true,
                      ),
                      const SizedBox(height: 10),
                      _PerkRow(
                        icon: Icons.schedule_rounded,
                        label: AppStrings.t('boost_pw_row_duration'),
                        value: AppStrings.t('boost_pw_row_duration_value'),
                        on: true,
                      ),
                      const Spacer(),
                      const SizedBox(height: 22),
                      _TwoLineCta(
                        title: AppStrings.t('boost_my_profile'),
                        subtitle: ctaSub,
                        busy: _busy,
                        onPressed: _buy,
                      ),
                      const SizedBox(height: 12),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _FooterLink(
                              AppStrings.t('paywall_terms'),
                              () => _openExternal(
                                'https://www.swayco.fr/terms',
                              ),
                            ),
                            const _FooterDot(),
                            _FooterLink(
                              AppStrings.t('paywall_privacy'),
                              () => _openExternal(
                                'https://www.swayco.fr/privacy',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 1b — Wall of blurred likes
// ══════════════════════════════════════════════════════════════════════════

class _LikesWallPaywall extends StatefulWidget {
  const _LikesWallPaywall({
    required this.likers,
    required this.videoAvailable,
    required this.onWatchVideo,
  });

  final List<RemoteProfile?> likers;
  final bool videoAvailable;
  final VoidCallback onWatchVideo;

  @override
  State<_LikesWallPaywall> createState() => _LikesWallPaywallState();
}

class _LikesWallPaywallState extends State<_LikesWallPaywall>
    with _PaywallPurchase {
  @override
  void initState() {
    super.initState();
    _loadPrice();
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final count = widget.likers.length;
    final countLabel = count == 1
        ? AppStrings.t('pw_likes_count_one')
        : AppStrings.t('pw_likes_count', args: {'n': '$count'});
    final price = _price;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: SC.dBg,
        body: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 430,
              child: _BlurredWall(likers: widget.likers),
            ),
            // Lock in the middle of the wall.
            Positioned(
              top: 210,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 76,
                  height: 76,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SC.brandGradient,
                    boxShadow: [
                      BoxShadow(
                        color: SC.brandBlue.withValues(alpha: 0.9),
                        blurRadius: 40,
                        spreadRadius: -6,
                      ),
                    ],
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: SC.dBg,
                    ),
                    child: Icon(Icons.lock_rounded, size: 34, color: SC.accent),
                  ),
                ),
              ),
            ),
            Positioned(
              top: safe.top + 12,
              left: 18,
              child: _CloseButton(
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            Positioned.fill(
              top: 330,
              child: _ScrollFill(
                padding: EdgeInsets.fromLTRB(22, 0, 22, safe.bottom + 14),
                child: Column(
                  children: [
                    if (count > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: SC.accent,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: SC.accent.withValues(alpha: 0.45),
                              blurRadius: 28,
                              spreadRadius: -4,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.favorite_rounded,
                              size: 18,
                              color: SC.onAccent,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                countLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: SC.onAccent,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 18),
                    _HighlightTitle(
                      head: AppStrings.t('pw_likes_title_head'),
                      tail: AppStrings.t('pw_likes_title_tail'),
                      fontSize: 28,
                      tailBg: SC.accent,
                      tailFg: SC.onAccent,
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Text(
                        AppStrings.t('pw_likes_sub'),
                        textAlign: TextAlign.center,
                        style: SCText.subtitle.copyWith(
                          fontSize: 14.5,
                          height: 1.5,
                          color: SC.dTextPrimary.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _PlanCard(price: price),
                    const Spacer(),
                    const SizedBox(height: 20),
                    PopupButton(
                      label: AppStrings.t('paywall_cta'),
                      height: 56,
                      busy: _busy,
                      onPressed: _subscribe,
                    ),
                    const SizedBox(height: 8),
                    _VideoButton(
                      label: widget.videoAvailable
                          ? AppStrings.t('pw_video_reveal')
                          : '${AppStrings.t('pw_video_reveal')} · '
                              '${AppStrings.t('likes_video_soon')}',
                      onTap: () {
                        Navigator.of(context).pop();
                        widget.onWatchVideo();
                      },
                    ),
                    const SizedBox(height: 12),
                    _legalDisclosure(),
                    const SizedBox(height: 10),
                    _footer(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 3×2 wall of tiles, tilted −4° and blurred: the likers' real photos when
/// there are some, warm colour tiles otherwise. Fades into blue, then black.
class _BlurredWall extends StatelessWidget {
  const _BlurredWall({required this.likers});

  final List<RemoteProfile?> likers;

  static const _swatches = [
    [Color(0xFFC2715A), Color(0xFF6B3B30)],
    [Color(0xFF8C8A4B), Color(0xFF3B3C22)],
    [Color(0xFF9B6F66), Color(0xFF463531)],
    [Color(0xFFB0596E), Color(0xFF4A2230)],
    [Color(0xFFA26C54), Color(0xFF45291F)],
    [Color(0xFF5E9A5B), Color(0xFF26431F)],
  ];

  @override
  Widget build(BuildContext context) {
    final photos = [
      for (final p in likers)
        if (p != null && p.fallbackPhotoUrl.isNotEmpty)
          p.fallbackPhotoUrl
        else if (p != null && p.avatarUrl.isNotEmpty)
          p.avatarUrl,
    ];
    Widget tile(int i) {
      final sw = _swatches[i % _swatches.length];
      return Container(
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: sw,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: i < photos.length
            ? Image.network(
                photos[i],
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              )
            : null,
      );
    }

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -20,
            left: -20,
            right: -20,
            bottom: -20,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Transform.rotate(
                angle: -4 * math.pi / 180,
                child: Transform.scale(
                  scale: 1.1,
                  child: Column(
                    children: [
                      for (var r = 0; r < 2; r++) ...[
                        if (r > 0) const SizedBox(height: 10),
                        Row(
                          children: [
                            for (var c = 0; c < 3; c++) ...[
                              if (c > 0) const SizedBox(width: 10),
                              Expanded(child: tile(r * 3 + c)),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x260E0E0E), Color(0x401F5EFF), SC.dBg],
                stops: [0, 0.4, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Swayco Pro — Likes révélés · badge Pro — 6,99 € / mois", selected look.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.price});

  final String? price;

  @override
  Widget build(BuildContext context) {
    final p = price;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: SC.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SC.accent, width: 1.6),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: SC.accent,
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 15,
              color: SC.onAccent,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Swayco Pro',
                  style: popupDisplay(fontSize: 16, color: SC.dTextPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  AppStrings.t('pw_plan_perks'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: SC.dTextPrimary.withValues(alpha: 0.6),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (p != null) ...[
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(p, style: popupDisplay(fontSize: 16, color: SC.accent)),
                Text(
                  AppStrings.t('paywall_period_month'),
                  style: TextStyle(
                    color: SC.dTextPrimary.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Secondary action of 1b: brand-gradient pill, white label, blue shadow.
class _VideoButton extends StatelessWidget {
  const _VideoButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        gradient: SC.brandGradient,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: SC.brandBlue.withValues(alpha: 0.4),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Shared bits
// ══════════════════════════════════════════════════════════════════════════

/// Scrolls only when it must (small phones); otherwise fills the height so a
/// [Spacer] inside [child] pushes the CTA down to the bottom.
class _ScrollFill extends StatelessWidget {
  const _ScrollFill({required this.child, required this.padding});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, box.maxHeight - padding.vertical),
          ),
          child: IntrinsicHeight(child: child),
        ),
      ),
    );
  }
}

/// Title whose tail sits on a pill that never breaks across lines.
class _HighlightTitle extends StatelessWidget {
  const _HighlightTitle({
    required this.head,
    required this.tail,
    required this.fontSize,
    required this.tailBg,
    required this.tailFg,
  });

  final String head;
  final String tail;
  final double fontSize;
  final Color tailBg;
  final Color tailFg;

  @override
  Widget build(BuildContext context) {
    final style = popupDisplay(
      fontSize: fontSize,
      letterSpacing: -fontSize * 0.03,
      height: 1.18,
      color: SC.dTextPrimary,
    );
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: '$head '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: tailBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(tail, style: style.copyWith(color: tailFg)),
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: CircleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.close_rounded, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

class _FooterLink extends StatelessWidget {
  const _FooterLink(this.label, this.onTap);

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SC.dTextPrimary.withValues(alpha: 0.55);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          style: TextStyle(
            color: c,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: c,
          ),
        ),
      ),
    );
  }
}

class _FooterDot extends StatelessWidget {
  const _FooterDot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        '·',
        style: TextStyle(
          color: SC.dTextPrimary.withValues(alpha: 0.55),
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Les arguments du Pro : grille 2 x 2 de pastilles (coche jaune + texte).
/// Hors Pro, les coches et le texte s'eteignent.
class _PerkGrid extends StatelessWidget {
  const _PerkGrid({required this.labels, required this.on});

  final List<String> labels;
  final bool on;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label) {
      return Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? SC.accent : Colors.white.withValues(alpha: 0.18),
              ),
              child: Icon(
                Icons.check_rounded,
                size: 14,
                color: on ? SC.onAccent : Colors.white.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: SC.dTextPrimary.withValues(alpha: on ? 1 : 0.5),
                  fontSize: 14,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < labels.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          // IntrinsicHeight : la ligne est dans une colonne a hauteur libre,
          // un Row « stretch » y planterait (hauteur infinie) et la grille
          // disparaitrait.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: chip(labels[i])),
                const SizedBox(width: 10),
                Expanded(
                  child: i + 1 < labels.length
                      ? chip(labels[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
