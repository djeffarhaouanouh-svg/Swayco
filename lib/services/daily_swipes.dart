import 'package:shared_preferences/shared_preferences.dart';

import 'revenue_cat.dart';

/// Compteur de swipes du jour : un compte gratuit a [freeLimit] profils par
/// jour (date locale), le Pro est illimité. Local à l'appareil.
class DailySwipes {
  DailySwipes._();

  /// 50 par jour pour un compte gratuit (c'était 100) : même nombre que la taille
  /// du paquet du jour (`kDiscoverDailySwipes`) et que le « n / max » de l'écran
  /// de fin.
  static const int freeLimit = 50;

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

  static const _kSeen = 'swipes_seen';

  /// Le profil [id] vient d'être vu dans le fil : compté une seule fois par
  /// jour, même si on repasse dessus.
  static Future<void> markSeen(String id) {
    // À la file : deux cartes dépassées d'un coup comptent pour deux.
    return _queue = _queue.then((_) async {
      final p = await SharedPreferences.getInstance();
      final today = _today();
      final raw = p.getStringList(_kSeen) ?? const <String>[];
      final seen = raw.isNotEmpty && raw.first == today
          ? raw.sublist(1)
          : <String>[];
      if (seen.contains(id)) return;
      await p.setStringList(_kSeen, [today, ...seen, id]);
      await increment();
    }).catchError((_) {});
  }

  static Future<void> _queue = Future<void>.value();

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
