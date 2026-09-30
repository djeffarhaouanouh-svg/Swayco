import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/revenue_cat.dart';
import '../theme/swayco_theme.dart';

/// "Booster mon profil" — buys the consumable Boost package through
/// RevenueCat. The backend webhook credits it (24 h in Discover); while it
/// runs the button shows the end time instead. Used on the own profile
/// (above "Mes photos") and under the card in the "how others see you"
/// preview.
class BoostButton extends StatefulWidget {
  const BoostButton({
    super.key,
    required this.boostedUntil,
    required this.onPurchased,
  });

  final DateTime? boostedUntil;
  final Future<void> Function() onPurchased;

  @override
  State<BoostButton> createState() => _BoostButtonState();
}

class _BoostButtonState extends State<BoostButton> {
  bool _busy = false;

  Future<void> _buy() async {
    setState(() => _busy = true);
    final outcome = await RevenueCat.purchaseConsumable(
      RevenueCat.boostPackageId,
    );
    if (!mounted) return;
    final key = switch (outcome) {
      PurchaseOutcome.success => 'boost_snack_success',
      PurchaseOutcome.unavailable => 'paywall_snack_unavailable',
      PurchaseOutcome.error => 'paywall_snack_error',
      PurchaseOutcome.cancelled => null,
    };
    if (key != null) {
      final why = outcome == PurchaseOutcome.unavailable
          ? RevenueCat.lastUnavailableReason
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: Duration(seconds: why.isEmpty ? 4 : 8),
          content: Text(
            why.isEmpty ? AppStrings.t(key) : '${AppStrings.t(key)}\n($why)',
          ),
        ),
      );
    }
    if (outcome == PurchaseOutcome.success) await widget.onPurchased();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final until = widget.boostedUntil;
    final active = until != null && until.isAfter(DateTime.now());
    final String label;
    if (active) {
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(until));
      label = AppStrings.t('boost_active_until', args: {'time': time});
    } else {
      label = AppStrings.t('boost_my_profile');
    }
    final radius = BorderRadius.circular(16);
    // Même dégradé que le bouton message de Discover ; lueur bien plus
    // discrète, sa taille la rendrait envahissante. Boost déjà actif :
    // simple pastille bleutée, sans lueur.
    return Container(
      decoration: active
          ? null
          : BoxDecoration(
              gradient: SC.brandGradient,
              borderRadius: radius,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x262B7FFF),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
      child: FilledButton.icon(
        onPressed: active || _busy ? null : _buy,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: active
              ? SC.brandBlue.withValues(alpha: 0.18)
              : Colors.transparent,
          disabledForegroundColor: active ? SC.brandCyan : Colors.white,
          shadowColor: Colors.transparent,
          elevation: 0,
          // Resserré : largeur du contenu, pas toute la page.
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.rocket_launch_rounded, size: 20),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
