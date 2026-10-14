import 'package:shared_preferences/shared_preferences.dart';

import 'revenue_cat.dart';

/// Compteur de swipes du jour : un compte gratuit a [freeLimit] profils par
/// jour (date locale), le Pro est illimité. Local à l'appareil.
class DailySwipes {
  DailySwipes._();

  static const int freeLimit = 100;

  static const _kDay = 'swipes_day';
  static const _kCount = 'swipes_count';

  static String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// Swipes faits aujourd'hui ; remet à 0 quand le jour a changé.
  static Future<int> count() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kDay) != _today()) {
      await p.setString(_kDay, _today());
      await p.setInt(_kCount, 0);
      return 0;
    }
    return p.getInt(_kCount) ?? 0;
  }

  static Future<void> increment() async {
    final n = await count();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kCount, n + 1);
  }

  static Future<void> reset() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDay, _today());
    await p.setInt(_kCount, 0);
  }

  static Future<bool> reached() async {
    if (RevenueCat.proActive.value) return false;
    return await count() >= freeLimit;
  }

  /// Prochain minuit local : le minuteur de l'écran de fin décompte jusque-là.
  static DateTime nextReset() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + 1);
  }
}
