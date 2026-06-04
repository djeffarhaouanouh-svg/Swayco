import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/stripe_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';

/// Opens the subscription paywall as a modal sheet that slides up from
/// the bottom (rounded top corners, grab handle, dismiss by swipe / tap
/// outside). Call this from anywhere — e.g. the profile's "Mon
/// abonnement" row.
Future<void> showPaywallSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => const _PaywallSheet(),
  );
}

/// Subscription paywall — Swayco "Midnight" reskin of the classic store
/// layout, presented as a bottom sheet: grab handle + close, a
/// social-proof pill, a bold headline + value prop, the logo as hero
/// art, a stack of radio-selectable plan cards (prices mirror the
/// profile tiers), a single CTA acting on the selected plan, and the
/// legal / restore footer.
///
/// Dark navy surface, hairline grey card borders, cyan accent on the
/// selected card + CTA — matching [SC] everywhere instead of the pink
/// reference it was adapted from.
class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet();

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  /// Currently highlighted plan (cyan border + filled radio + cyan
  /// price). Defaults to the entry paid tier — the subscribe CTA
  /// converts best anchored on the cheaper recurring plan, with the
  /// pricier tier sitting just above as an upsell.
  String _selected = 'plus';

  bool _busy = false;

  // Plan copy. Prices are the single source of truth shared with the
  // profile tier ladder — keep them in sync (9,99 / 15,99).
  static const List<_Plan> _plans = [
    _Plan(
      tier: 'plus',
      name: 'Plus',
      price: '9,99 €',
      period: '/mois',
      // Highlighted (cyan) fragments are wrapped in *asterisks* and
      // split out at render time, mirroring the green words in the
      // reference paywall.
      sublabel: 'Heures d\'appel *incluses*',
      popular: true,
    ),
    _Plan(
      tier: 'ultra_plus',
      name: 'Ultra Plus',
      price: '15,99 €',
      period: '/mois',
      sublabel: 'Heures d\'appel *illimitées*',
      popular: false,
    ),
  ];

  Future<void> _subscribe() async {
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
    // Cap the sheet height so a tall screen doesn't stretch it edge to
    // edge — it should read as a window that slid up, not a full page.
    final maxH = MediaQuery.of(context).size.height * 0.9;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Container(
        decoration: const BoxDecoration(
          color: SC.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          border: Border(
            top: BorderSide(color: SC.glassBorderStrong),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grab handle.
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SC.glassBorderStrong,
                borderRadius: BorderRadius.circular(999),
              ),
            ),

            // Top row: social-proof pill centred, close button left.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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

            // Scrollable hero + plans (shrinks to content when short,
            // scrolls once it would overflow the capped height).
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    Text(
                      'Activez votre abonnement\net parlez sans limite',
                      textAlign: TextAlign.center,
                      style: SCText.h1.copyWith(fontSize: 25, height: 1.12),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Parlez toutes les langues, sans barrière. '
                      'Traduction vocale et messages, en temps réel.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: SC.textMuted,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _HeroLogo(),
                    const SizedBox(height: 26),
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

            // Pinned CTA + footer.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _subscribe,
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
                          'S\'abonner',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 12),
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

/// Social-proof chip at the top — glass pill, cyan verified badge.
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
      width: 132,
      height: 132,
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
        width: 100,
        height: 100,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.translate_rounded, size: 84, color: SC.accent),
      ),
    );
  }
}

/// One selectable plan card: radio on the left, name + sub-label
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
