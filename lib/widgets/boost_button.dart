import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';
import 'sparkles.dart';

/// « Booster mon profil » en pastille jaune (barre du haut du profil) : même
/// offre que [BoostButton], format compact.
class BoostPill extends StatelessWidget {
  const BoostPill({
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
    final label = active
        ? AppStrings.t(
            'boost_active_until',
            args: {
              'time': MaterialLocalizations.of(context)
                  .formatTimeOfDay(TimeOfDay.fromDateTime(until)),
            },
          )
        : AppStrings.t('boost_pill');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: active
          ? null
          : () => showBoostPaywall(context, onPurchased: onPurchased),
      child: Sparkles(
        color: active ? SC.brandCyan : Colors.white,
        count: 5,
        child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? SC.brandBlue.withValues(alpha: 0.3) : SC.accent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.rocket_launch_rounded,
                size: 18,
                color: active ? SC.brandCyan : SC.onAccent,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                maxLines: 1,
                style: popupDisplay(
                  fontSize: 14,
                  letterSpacing: -0.2,
                  color: active ? SC.brandCyan : SC.onAccent,
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
    this.wide = false,
  });

  final DateTime? boostedUntil;
  final Future<void> Function() onPurchased;

  /// Profil 6b : barre pleine largeur de 56 (au dégradé de marque, rond jaune
  /// + fusée) au lieu du bouton qui épouse son contenu.
  final bool wide;

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
    if (wide) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: active
            ? null
            : () => showBoostPaywall(context, onPurchased: onPurchased),
        child: _sparkle(
          active,
          20,
          Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            gradient: active
                ? null
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [SC.brandBlueDeep, SC.brandBlue, SC.brandCyan],
                    stops: [0, 0.52, 1],
                  ),
            color: active ? SC.brandBlue.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(20),
            boxShadow: active
                ? null
                : [
                    BoxShadow(
                      color: SC.brandBlue.withValues(alpha: 0.4),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: SC.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.rocket_launch_rounded,
                  size: 19,
                  color: SC.onAccent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: popupDisplay(
                    fontSize: 15,
                    letterSpacing: -0.3,
                    color: active ? SC.brandCyan : SC.fg,
                  ),
                ),
              ),
              if (!active)
                Icon(Icons.chevron_right, size: 22, color: SC.fg),
            ],
          ),
        ),
        ),
      );
    }
    final radius = BorderRadius.circular(16);
    // Même dégradé que le bouton message de Discover ; lueur bien plus
    // discrète, sa taille la rendrait envahissante. Boost déjà actif :
    // simple pastille bleutée, sans lueur.
    return _sparkle(
      active,
      16,
      Container(
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
          foregroundColor: SC.fg,
          disabledBackgroundColor: active
              ? SC.brandBlue.withValues(alpha: 0.18)
              : Colors.transparent,
          disabledForegroundColor: active ? SC.brandCyan : SC.fg,
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
      ),
    );
  }

  /// Etincelles par-dessus le bouton tant que le Boost n'est pas actif.
  static Widget _sparkle(bool active, double radius, Widget child) => active
      ? child
      : Sparkles(borderRadius: radius, count: 7, child: child);
}
