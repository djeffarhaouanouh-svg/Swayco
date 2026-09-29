import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/paywall_screen.dart';
import '../services/app_strings.dart';
import '../services/revenue_cat.dart';
import '../theme/swayco_theme.dart';

const _kInfoSeenKey = 'ad_info_sheet_seen';
const _kUpsellAtKey = 'ad_upsell_sheet_at';

/// Minimum gap between two "go Premium" sheets.
const _kUpsellGap = Duration(hours: 24);

/// Called right after a full-screen ad the user actually watched.
///
/// The very first time: the "how to skip ads" sheet (once per install).
/// After that: the "enjoy Swayco ad-free" Premium sheet, at most once a day.
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
      isScrollControlled: true,
      builder: (_) => sheet,
    );

const _kSurface = Color(0xFF1A1A1D);
const _kChip = Color(0xFF2A2A2E);

/// Shared look of both sheets: dark rounded card, ✕ top-right, cyan CTA.
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
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _kChip),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    color: _kChip,
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
            const SizedBox(height: 4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 12),
            body,
            if (extra != null) ...[const SizedBox(height: 18), extra!],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onCta,
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: const Color(0xFF0B0B0C),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
                child: Text(
                  ctaLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _kBodyStyle = TextStyle(color: SC.textMuted, fontSize: 14, height: 1.35);

/// "Ads can be skipped after a few seconds…" + the skip-button icons.
class _AdInfoSheet extends StatelessWidget {
  const _AdInfoSheet();

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      title: AppStrings.t('ad_info_title'),
      body: Text(
        AppStrings.t('ad_info_body'),
        textAlign: TextAlign.center,
        style: _kBodyStyle,
      ),
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
      width: 38,
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _kChip,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

/// "Enjoy Swayco ad-free by going Premium" — price from the store, the CTA
/// pops `true` so the caller opens the real paywall (purchase + legal).
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
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            TextSpan(text: AppStrings.t('ad_upsell_terms')),
          ],
        ),
        textAlign: TextAlign.center,
        style: _kBodyStyle,
      ),
      ctaLabel: AppStrings.t('ad_upsell_cta'),
      onCta: () => Navigator.of(context).pop(true),
    );
  }
}
