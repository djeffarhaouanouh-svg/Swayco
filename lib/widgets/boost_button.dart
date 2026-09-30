import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// "Booster mon profil" — opens the Boost offer screen ([showBoostPaywall]),
/// which buys the consumable Boost package through RevenueCat. The backend
/// webhook credits it (24 h at the top of Discover); while it runs the button
/// shows the end time instead. Used on the own profile (above "Mes photos")
/// and under the card in the "how others see you" preview.
class BoostButton extends StatelessWidget {
  const BoostButton({
    super.key,
    required this.boostedUntil,
    required this.onPurchased,
  });

  final DateTime? boostedUntil;
  final Future<void> Function() onPurchased;

  @override
  Widget build(BuildContext context) {
    final until = boostedUntil;
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
        onPressed: active
            ? null
            : () => showBoostPaywall(context, onPurchased: onPurchased),
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
        icon: const Icon(Icons.rocket_launch_rounded, size: 20),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
