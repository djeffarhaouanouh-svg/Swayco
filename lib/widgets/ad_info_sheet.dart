import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/paywall_screen.dart';
import '../services/app_strings.dart';
import '../services/revenue_cat.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

const _kInfoSeenKey = 'ad_info_sheet_seen';
const _kUpsellAtKey = 'ad_upsell_sheet_at';

/// Minimum gap between two "go Premium" sheets.
const _kUpsellGap = Duration(hours: 24);

/// Appelée juste après une pub regardée en entier (direction 8c). Logique
/// inchangée : 1re fois = feuille « comment passer les pubs », ensuite =
/// feuille Premium, au plus une fois par jour.
Future<void> showAfterAdSheet(BuildContext context) async {
  final SharedPreferences p;
  try {
    p = await SharedPreferences.getInstance();
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  if (!(p.getBool(_kInfoSeenKey) ?? false)) {
    await p.setBool(_kInfoSeenKey, true);
    if (!context.mounted) return;
    await _show(context, const _AdInfoSheet());
    return;
  }
  if (RevenueCat.proActive.value) return;
  final last = DateTime.tryParse(p.getString(_kUpsellAtKey) ?? '');
  if (last != null && DateTime.now().difference(last) < _kUpsellGap) return;
  await p.setString(_kUpsellAtKey, DateTime.now().toIso8601String());
  if (!context.mounted) return;
  final goPremium = await _show<bool>(context, const _AdUpsellSheet());
  if (goPremium == true && context.mounted) await showPaywallSheet(context);
}

Future<T?> _show<T>(BuildContext context, Widget sheet) =>
    showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: true,
      builder: (_) => sheet,
    );

class _SheetShell extends StatelessWidget {
  const _SheetShell({
    required this.title,
    required this.body,
    required this.ctaLabel,
    required this.onCta,
    this.extra,
  });

  final String title;
  final Widget body;
  final Widget? extra;
  final String ctaLabel;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    return PopupSurface(
      sheet: true,
      washHeight: 140,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  const PopupHandle(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(
                          color: PopupTokens.ghost,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              PopupTitle(title, fontSize: 21),
              const SizedBox(height: 12),
              body,
              if (extra != null) ...[const SizedBox(height: 18), extra!],
              const SizedBox(height: 22),
              PopupButton(label: ctaLabel, height: 54, onPressed: onCta),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdInfoSheet extends StatelessWidget {
  const _AdInfoSheet();

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      title: AppStrings.t('ad_info_title'),
      body: PopupBody(AppStrings.t('ad_info_body')),
      extra: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _SkipIcon(Icons.keyboard_double_arrow_right_rounded),
          _SkipIcon(Icons.last_page_rounded),
          _SkipIcon(Icons.close_rounded),
          _SkipIcon(Icons.skip_next_rounded),
        ],
      ),
      ctaLabel: 'OK',
      onCta: () => Navigator.of(context).pop(),
    );
  }
}

class _SkipIcon extends StatelessWidget {
  const _SkipIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: PopupTokens.ghost,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PopupTokens.ghostBorder),
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

class _AdUpsellSheet extends StatefulWidget {
  const _AdUpsellSheet();

  @override
  State<_AdUpsellSheet> createState() => _AdUpsellSheetState();
}

class _AdUpsellSheetState extends State<_AdUpsellSheet> {
  String? _price;

  @override
  void initState() {
    super.initState();
    if (RevenueCat.isSupported) {
      RevenueCat.priceOf(RevenueCat.proPackageId).then((p) {
        if (mounted) setState(() => _price = p);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = _price;
    return _SheetShell(
      title: AppStrings.t('ad_upsell_title'),
      body: Text.rich(
        TextSpan(
          children: [
            if (price != null)
              TextSpan(
                text: '$price${AppStrings.t('paywall_period_month')}\n',
                style: const TextStyle(
                  color: SC.accent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            TextSpan(text: AppStrings.t('ad_upsell_terms')),
          ],
        ),
        textAlign: TextAlign.center,
        style: SCText.subtitle.copyWith(
          fontSize: 14,
          height: 1.45,
          color: Colors.white.withValues(alpha: 0.72),
        ),
      ),
      ctaLabel: AppStrings.t('ad_upsell_cta'),
      onCta: () => Navigator.of(context).pop(true),
    );
  }
}

