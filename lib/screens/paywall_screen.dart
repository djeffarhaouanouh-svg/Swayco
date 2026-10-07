import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_strings.dart';
import '../services/swayco_sounds.dart';
import '../services/device_id.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/stripe_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/fade_scale_route.dart';
import '../widgets/likes_lock.dart' show BlurredAvatar;
import '../widgets/popup_kit.dart';
import '../widgets/sparkles.dart';
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
  RemoteProfile? profile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor:
        SC.light ? const Color(0x4D04123A) : const Color(0x99040A1E),
    builder: (_) => _LikesSheet(
      likers: likers,
      profile: profile ?? (likers.isEmpty ? null : likers.first),
      videoAvailable: videoAvailable,
      onWatchVideo: onWatchVideo,
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
  Widget _legalDisclosure({Color? color}) {
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
        color: color ?? Colors.white.withValues(alpha: 0.4),
        fontSize: 10,
        height: 1.35,
      ),
    );
  }

  /// "Restaurer · Conditions · Confidentialité" on ONE line.
  Widget _footer({Color? color}) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FooterLink(AppStrings.t('paywall_restore'), _restore, color: color),
          _FooterDot(color: color),
          _FooterLink(
            AppStrings.t('paywall_terms'),
            () => _openExternal('https://www.swayco.fr/terms'),
            color: color,
          ),
          _FooterDot(color: color),
          _FooterLink(
            AppStrings.t('paywall_privacy'),
            () => _openExternal('https://www.swayco.fr/privacy'),
            color: color,
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
                        items: [
                          (
                            'assets/icons/pro/pro_populaire.svg',
                            AppStrings.t('pw_arg_badge'),
                          ),
                          (
                            'assets/icons/pro/pro_qui_ma_like.svg',
                            AppStrings.t('pw_arg_likes'),
                          ),
                          (
                            'assets/icons/pro/pro_visibilite.svg',
                            AppStrings.t('pw_arg_visibility'),
                          ),
                          (
                            'assets/icons/pro/pro_messages_speciaux.svg',
                            AppStrings.t('pw_arg_special'),
                          ),
                          (
                            'assets/icons/pro/pro_moins_de_pub.svg',
                            AppStrings.t('pw_arg_less_ads'),
                          ),
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
      // Le vrai drapeau (pays, sinon langue) a la place du code « EN ».
      if (p != null)
        (countryFlagFor(p.country) ??
            findLanguageByCode(p.language)?.flag ??
            ''),
    ].where((s) => s.isNotEmpty).join(' · ');
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
                  // Etincelles sur la pastille « POPULAIRE » / « BOOSTE ».
                  child: Sparkles(
                    color: SC.onAccent,
                    count: 5,
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
            // Icone en jaune ; le rond garde son fond degrade.
            child: Icon(icon, size: 17, color: SC.accent),
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
// Pop-up Likes (A / A2) — feuille du bas sur la liste des demandes
// ══════════════════════════════════════════════════════════════════════════

class _LikesSheet extends StatefulWidget {
  const _LikesSheet({
    required this.likers,
    required this.profile,
    required this.videoAvailable,
    required this.onWatchVideo,
  });

  final List<RemoteProfile?> likers;

  /// La personne touchée dans la liste.
  final RemoteProfile? profile;
  final bool videoAvailable;
  final VoidCallback onWatchVideo;

  @override
  State<_LikesSheet> createState() => _LikesSheetState();
}

class _LikesSheetState extends State<_LikesSheet> with _PaywallPurchase {
  @override
  void initState() {
    super.initState();
    _loadPrice();
  }

  /// « au Japon », « en France », « aux États-Unis » : la préposition française
  /// dépend du pays ; les autres langues portent la leur dans la chaîne.
  String _countryLabel(String country, String iso) {
    final localized = iso.isEmpty ? '' : AppStrings.t('country_$iso');
    final name =
        localized.isNotEmpty && localized != 'country_$iso' ? localized : country;
    if (!AppStrings.currentBcp47.value.toLowerCase().startsWith('fr')) {
      return name;
    }
    const plural = {'États-Unis', 'Pays-Bas', 'Émirats arabes unis'};
    const masculineE = {'Mexique', 'Cambodge', 'Mozambique'};
    if (plural.contains(country)) return 'aux $name';
    if (masculineE.contains(country)) return 'au $name';
    final feminine = country.endsWith('e') || country == 'Corée du Sud';
    return feminine ? 'en $name' : 'au $name';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final others = [
      for (final l in widget.likers)
        if (l != null && l.id != p?.id) l,
    ];
    final many = widget.likers.length > 1;
    final total = widget.likers.length;
    final country = p?.country.trim() ?? '';
    final iso = countryIso2For(country);
    final hasCountry = country.isNotEmpty;
    final price = _price;
    final perMonth = AppStrings.t('paywall_period_month');

    // Drapeaux des AUTRES likers : pays distincts d'abord, 5 au plus.
    final seen = <String>{};
    final flagIsos = <String>[];
    var extra = 0;
    if (many) {
      for (final o in others) {
        final c = countryIso2For(o.country.trim());
        if (c.isEmpty || c == iso) continue;
        if (seen.add(c)) {
          if (flagIsos.length < 5) {
            flagIsos.add(c);
          } else {
            extra++;
          }
        }
      }
    }

    final proSub = many
        ? AppStrings.t('pw_pro_reveal_n', args: {'n': '$total'})
        : AppStrings.t('pw_pro_all_likes');
    final proSubFull =
        price == null ? proSub : '$proSub · $price$perMonth';
    final videoLabel = widget.videoAvailable
        ? AppStrings.t(many ? 'pw_video_reveal_only' : 'pw_video_reveal_one')
        : AppStrings.t('likes_video_soon');

    final ink = PopupTokens.ink;
    final titleStyle = popupDisplay(
      fontSize: 25,
      letterSpacing: -0.75,
      height: 1.2,
      color: ink,
    );
    final head = hasCountry
        ? AppStrings.t(
            'pw_likes_one_title',
            args: {'country': _countryLabel(country, iso)},
          )
        : AppStrings.t('pw_likes_one_title_nocountry');

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: PopupSurface(
        sheet: true,
        washHeight: 170,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: PopupHandle()),
                const SizedBox(height: 6),
                Center(
                  child: _LockedAvatar(
                    profile: p,
                    iso: hasCountry ? iso : '',
                    country: hasCountry ? country : '',
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 2,
                  children: [
                    Text(head, textAlign: TextAlign.center, style: titleStyle),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: SC.accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        AppStrings.t('pw_likes_pill'),
                        softWrap: false,
                        style: titleStyle.copyWith(color: SC.onAccent),
                      ),
                    ),
                    Text('!', style: titleStyle),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  many
                      ? AppStrings.t(
                          'pw_likes_many_sub',
                          args: {'n': '${total - 1}'},
                        )
                      : AppStrings.t('pw_likes_one_sub'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: PopupTokens.textBody,
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (flagIsos.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final c in flagIsos)
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: PopupTokens.ghost,
                            border: Border.all(color: PopupTokens.ghostBorder),
                          ),
                          child: _RoundFlag(iso: c, size: 20),
                        ),
                      if (extra > 0)
                        Container(
                          height: 34,
                          constraints: const BoxConstraints(minWidth: 34),
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: SC.accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '+$extra',
                            style: const TextStyle(
                              color: SC.onAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Sparkles(
                  color: SC.onAccent,
                  child: _TwoLineCta(
                    title: AppStrings.t('pw_pro_switch'),
                    subtitle: proSubFull,
                    busy: _busy,
                    onPressed: _subscribe,
                  ),
                ),
                const SizedBox(height: 10),
                _VideoButton(
                  title: AppStrings.t('pw_watch_ad'),
                  subtitle: videoLabel,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onWatchVideo();
                  },
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      AppStrings.t('pw_later'),
                      style: TextStyle(
                        color: ink.withValues(alpha: 0.6),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                _legalDisclosure(color: ink.withValues(alpha: 0.4)),
                const SizedBox(height: 8),
                _footer(color: ink.withValues(alpha: 0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Avatar flouté (96) dans un anneau de marque de 3 px, cadenas jaune en haut
/// à droite, pastille drapeau du pays en bas à droite.
class _LockedAvatar extends StatelessWidget {
  const _LockedAvatar({
    required this.profile,
    required this.iso,
    required this.country,
  });

  final RemoteProfile? profile;
  final String iso;
  final String country;

  @override
  Widget build(BuildContext context) {
    final surface = PopupTokens.surface;
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 96,
            height: 96,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SC.brandGradient,
              boxShadow: [
                BoxShadow(
                  color: SC.brandBlue.withValues(alpha: 0.8),
                  blurRadius: 26,
                  spreadRadius: -8,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: surface, width: 3),
              ),
              child: BlurredAvatar(profile: profile, size: 84, sigma: 9),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: SC.accent,
                shape: BoxShape.circle,
                border: Border.all(color: surface, width: 3),
              ),
              child: const Icon(Icons.lock_rounded, size: 15, color: SC.onAccent),
            ),
          ),
          if (iso.isNotEmpty || country.isNotEmpty)
            Positioned(
              right: -10,
              bottom: -10,
              child: Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: SC.accent, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: SC.accent.withValues(alpha: 0.45),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: _RoundFlag(iso: iso, country: country, size: 24),
              ),
            ),
        ],
      ),
    );
  }
}

/// Drapeau rond (flagcdn) ; l'emoji du pays à défaut.
class _RoundFlag extends StatelessWidget {
  const _RoundFlag({required this.iso, this.country = '', required this.size});

  final String iso;
  final String country;
  final double size;

  @override
  Widget build(BuildContext context) {
    final emoji = country.isEmpty ? null : countryFlagFor(country);
    Widget fallback() => emoji == null
        ? SizedBox(width: size, height: size)
        : Text(emoji, style: TextStyle(fontSize: size * 0.8, height: 1));
    if (iso.isEmpty) return fallback();
    return ClipOval(
      child: Image.network(
        'https://flagcdn.com/w80/${iso.toLowerCase()}.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      ),
    );
  }
}

/// Action secondaire : pilule au dégradé de marque, texte blanc, deux lignes.
class _VideoButton extends StatelessWidget {
  const _VideoButton({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        gradient: SC.brandGradient,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: SC.brandBlue.withValues(alpha: 0.6),
            blurRadius: 24,
            spreadRadius: -8,
            offset: const Offset(0, 10),
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 22,
                  color: Colors.white,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 11.5,
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
  const _FooterLink(this.label, this.onTap, {this.color});

  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? SC.dTextPrimary.withValues(alpha: 0.55);
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
  const _FooterDot({this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        '·',
        style: TextStyle(
          color: color ?? SC.dTextPrimary.withValues(alpha: 0.55),
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Les arguments du Pro : grille a 2 colonnes (icone sur fond degrade + texte) ;
/// un dernier argument seul prend toute la largeur. Hors Pro, tout s'eteint.
class _PerkGrid extends StatelessWidget {
  const _PerkGrid({required this.items, required this.on});

  /// (icone SVG, libelle)
  final List<(String, String)> items;
  final bool on;

  @override
  Widget build(BuildContext context) {
    Widget chip((String, String) item) {
      return Opacity(
        opacity: on ? 1 : 0.5,
        child: Container(
          constraints: const BoxConstraints(minHeight: 74),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1F2D),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment(-0.6, -1),
                    end: Alignment(0.6, 1),
                    colors: [SC.brandBlueDeep, SC.brandBlue, SC.brandCyan],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0xD92B7FFF),
                      blurRadius: 18,
                      spreadRadius: -8,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: SvgPicture.asset(
                  item.$1,
                  width: 36,
                  height: 36,
                  colorFilter: const ColorFilter.mode(
                    SC.accent,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.$2,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < items.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          // IntrinsicHeight : la ligne est dans une colonne a hauteur libre,
          // un Row « stretch » y planterait (hauteur infinie).
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: chip(items[i])),
                if (i + 1 < items.length) ...[
                  const SizedBox(width: 10),
                  Expanded(child: chip(items[i + 1])),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
