import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quels vocaux REÇUS ont déjà été écoutés. Local à l'appareil (aucune colonne en
/// base) : la clé est `voice_heard_<id du message>`.
///
/// Partagé entre le lecteur (qui le marque à la première lecture) et la bulle du
/// message (blanche tant que le vocal n'est pas écouté, grise ensuite) : les deux
/// doivent voir la même chose au même moment.
abstract final class VoiceHeard {
  static final Map<String, bool> _cache = {};

  /// Bouge à chaque changement : la bulle se met à jour sans rouvrir la liste.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static String _key(String id) => 'voice_heard_$id';

  /// Pour les tests : oublie ce qui est en mémoire (le disque, lui, reste).
  @visibleForTesting
  static void resetForTest() => _cache.clear();

  /// Ce qu'on sait déjà, sans attendre le disque ; `null` = pas encore lu.
  static bool? cached(String id) => _cache[id];

  static Future<bool> isHeard(String id) async {
    final known = _cache[id];
    if (known != null) return known;
    var heard = false;
    try {
      final p = await SharedPreferences.getInstance();
      heard = p.getBool(_key(id)) ?? false;
    } catch (_) {}
    _cache[id] = heard;
    changed.value++;
    return heard;
  }

  static Future<void> mark(String id) async {
    if (_cache[id] == true) return;
    _cache[id] = true;
    changed.value++;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_key(id), true);
    } catch (_) {}
  }
}
