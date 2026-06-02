import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/stripe_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/mesh_background.dart';

/// Full-screen subscription paywall — Swayco "Midnight" reskin of the
/// classic store layout: a social-proof pill, a bold headline + trial
/// promise, the logo as hero art, a stack of radio-selectable plan
/// cards (price pulled from the profile section's source of truth), a
/// single bottom CTA acting on the selected plan, and the legal /
/// restore footer.
///
/// Dark navy background, hairline grey card borders, cyan accent on the
/// selected card + CTA — matching [SC] everywhere instead of the pink
/// reference it was adapted from.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  /// Currently highlighted plan (cyan border + filled radio + cyan
  /// price). Defaults to the entry paid tier — the "start your trial"
  /// CTA converts best anchored on the cheaper recurring plan, with the
  /// pricier tier sitting just above as an upsell.
  String _selected = 'plus';

  bool _busy = false;

  // Plan copy. Prices are the single source of truth shared with the
  // profile's _PlansSection — keep the two in sync (9,99 / 15,99).
  static const List<_Plan> _plans = [
    _Plan(
      tier: 'plus',
      name: 'Plus',
      price: '9,99 €',
      period: '/mois',
      // Highlighted (cyan) fragments are wrapped in *asterisks* and
      // split out at render time, mirroring the green words in the
      // reference paywall.
      sublabel: 'Essai *gratuit* de *3 jours*',
      popular: true,
    ),
    _Plan(
      tier: 'ultra_plus',
      name: 'Ultra Plus',
      price: '15,99 €',
      period: '/mois',
      sublabel: 'Essai *gratuit* de *3 jours* · voix clonée',
      popular: false,
    ),
  ];

  Future<void> _startTrial() async {
    if (_busy) return;
    setState(() => _busy = true);
    final url = await StripeApi.startCheckout(_selected);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Impossible d'ouvrir la page de paiement. Réessaye dans un instant.",
          ),
        ),
      );
      return;
    }
    await launchUrl(
      Uri.parse(url),
      webOnlyWindowName: '_self',
      mode: LaunchMode.externalApplication,
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openExternal(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(url)));
    }
  }

  /// "Restaurer les achats" → opens the Stripe customer portal (where an
  /// existing subscription is re-attached / managed). Falls back to a
  /// toast on native where the portal is unavailable.
  Future<void> _restore() async {
    final url = await StripeApi.openPortal();
    if (!mounted) return;
    if (url != null && url.isNotEmpty) {
      await _openExternal(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aucun achat à restaurer pour le moment.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      body: MeshBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ── Top bar: social-proof pill centred, close button left.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const _SocialProofPill(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GlassIconButton(
                        icon: Icons.close,
                        iconSize: 18,
                        size: 36,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Scrollable hero + plans (keeps the CTA pinned below).
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Text(
                        'Activez votre abonnement\net profitez de 3 jours offerts',
                        textAlign: TextAlign.center,
                        style: SCText.h1.copyWith(fontSize: 27, height: 1.12),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Parlez toutes les langues, sans barrière. '
                        'Traduction vocale et messages, en temps réel.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: SC.textMuted,
                          fontSize: 14.5,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 28),
                      const _HeroLogo(),
                      const SizedBox(height: 32),
                      for (var i = 0; i < _plans.length; i++) ...[
                        if (i > 0) const SizedBox(height: 14),
                        _PlanTile(
                          plan: _plans[i],
                          selected: _selected == _plans[i].tier,
                          onTap: () =>
                              setState(() => _selected = _plans[i].tier),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ── Pinned CTA + footer.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _startTrial,
                    style: FilledButton.styleFrom(
                      backgroundColor: SC.accent,
                      foregroundColor: SC.bgDeep,
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: SC.bgDeep,
                            ),
                          )
                        : const Text(
                            'Commencer mon essai gratuit',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _FooterLink('Restaurer les achats', _restore),
                    const _FooterDot(),
                    _FooterLink(
                      'Conditions',
                      () => _openExternal('https://swayco.fr/terms'),
                    ),
                    const _FooterDot(),
                    _FooterLink(
                      'Confidentialité',
                      () => _openExternal('https://swayco.fr/privacy'),
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

/// Plain data holder for a single plan row.
class _Plan {
  const _Plan({
    required this.tier,
    required this.name,
    required this.price,
    required this.period,
    required this.sublabel,
    required this.popular,
  });

  final String tier;
  final String name;
  final String price;
  final String period;
  final String sublabel;
  final bool popular;
}

/// Social-proof chip at the very top — glass pill, cyan verified badge.
class _SocialProofPill extends StatelessWidget {
  const _SocialProofPill();

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      borderRadius: const BorderRadius.all(Radius.circular(999)),
      color: SC.glassStrong,
      border: SC.glassBorder,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: 16, color: SC.accent),
          SizedBox(width: 7),
          Text(
            'Plus de 10 000 utilisateurs nous font confiance',
            style: TextStyle(
              color: SC.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// App logo as hero art, sitting on a soft cyan glow (the reference's
/// pink sparkle halo, restyled to the Midnight accent).
class _HeroLogo extends StatelessWidget {
  const _HeroLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            SC.accent.withValues(alpha: 0.22),
            SC.accent.withValues(alpha: 0.0),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Image.asset(
        'assets/icon-fg-transparent.png',
        width: 112,
        height: 112,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.translate_rounded, size: 96, color: SC.accent),
      ),
    );
  }
}

/// One selectable plan card: radio on the left, name + trial sub-label
/// in the middle, price on the right. Selected → cyan border, faint cyan
/// fill, filled radio, cyan price.
class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  final _Plan plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: selected
            ? SC.accent.withValues(alpha: 0.08)
            : SC.glassStrong,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected ? SC.accent : const Color(0xFF2A3942),
          width: selected ? 1.6 : 1,
        ),
      ),
      child: Row(
        children: [
          _Radio(selected: selected),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.name,
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                _Sublabel(plan.sublabel),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                plan.price,
                style: TextStyle(
                  color: selected ? SC.accent : SC.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                plan.period,
                style: const TextStyle(
                  color: SC.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final tappable = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: card,
      ),
    );

    if (!plan.popular) return tappable;

    // "Populaire" ribbon clipped to the top-right corner of the card.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tappable,
        Positioned(
          top: -10,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: SC.accent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'Populaire',
              style: TextStyle(
                color: SC.bgDeep,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Custom radio dot — hollow grey ring when off, filled cyan with a
/// white centre tick when on.
class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? SC.accent : Colors.transparent,
        border: Border.all(
          color: selected ? SC.accent : const Color(0xFF3A4753),
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 15, color: SC.bgDeep)
          : null,
    );
  }
}

/// Renders a sublabel where *fragments* wrapped in asterisks are tinted
/// cyan and bolded (the "gratuit" / "3 jours" emphasis from the source
/// design).
class _Sublabel extends StatelessWidget {
  const _Sublabel(this.raw);

  final String raw;

  @override
  Widget build(BuildContext context) {
    // split('*') alternates plain / highlighted fragments: the
    // odd-indexed pieces are the ones that were wrapped in asterisks.
    final pieces = raw.split('*');
    final styled = <TextSpan>[];
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i].isEmpty) continue;
      final highlight = i.isOdd;
      styled.add(
        TextSpan(
          text: pieces[i],
          style: TextStyle(
            color: highlight ? SC.accent : SC.textMuted,
            fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      );
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(fontSize: 12.5, height: 1.3),
        children: styled,
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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          style: const TextStyle(
            color: SC.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: SC.textMuted,
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
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 10),
      child: Text('·', style: TextStyle(color: SC.textMuted, fontSize: 12)),
    );
  }
}
