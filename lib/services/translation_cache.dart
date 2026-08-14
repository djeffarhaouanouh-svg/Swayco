import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Les traductions déjà obtenues, gardées sur l'appareil.
///
/// Elles ne vivaient que dans l'état de l'écran : rouvrir un fil jetait tout et
/// redemandait au moteur la traduction de chaque message étranger encore à
/// l'écran. Une conversation de trente messages, ça fait trente requêtes payées
/// à chaque ouverture — pour un texte qui ne change jamais. Et ça se voyait :
/// les bulles s'affichaient dans la langue de l'autre, puis basculaient une à
/// une.
///
/// Rien à invalider : un message ne se réécrit pas. La seule chose qui peut
/// périmer une traduction, c'est la langue vers laquelle elle a été faite — et
/// elle est dans la clé, donc changer la langue de son compte repart d'un cache
/// vide au lieu de resservir l'ancienne.
abstract final class TranslationCache {
  /// Le nombre de traductions gardées par fil et par langue.
  ///
  /// Au-delà, les plus anciennes tombent. On ne relit pas mille messages en
  /// arrière, et un cache qui grossit sans fin finit par coûter plus cher à
  /// charger qu'il ne fait gagner.
  static const int _kMax = 300;

  /// Une entrée par (conversation, langue). Les deux doivent être dans la clé :
  /// un même message peut être lu dans deux langues si le compte change.
  static String _key(String convId, String lang) => 'xl8:$lang:$convId';

  /// Ce qui est déjà en mémoire pour ce fil — évite de relire le disque à
  /// chaque message traduit, puisque c'est nous qui l'écrivons.
  static final Map<String, Map<String, String>> _mem = {};

  static Future<Map<String, String>> load(String convId, String lang) async {
    if (convId.isEmpty || lang.isEmpty) return {};
    final k = _key(convId, lang);
    final cached = _mem[k];
    if (cached != null) return Map<String, String>.from(cached);
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(k);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, String>{
        for (final e in decoded.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
      _mem[k] = out;
      return Map<String, String>.from(out);
    } catch (e) {
      // Un cache illisible n'est pas une panne : on retraduit, c'est tout.
      debugPrint('TranslationCache.load failed: $e');
      return {};
    }
  }

  static Future<void> put({
    required String convId,
    required String lang,
    required String messageId,
    required String translated,
  }) async {
    if (convId.isEmpty || lang.isEmpty || messageId.isEmpty) return;
    if (translated.isEmpty) return;
    final k = _key(convId, lang);
    final map = _mem[k] ??= await load(convId, lang);
    map[messageId] = translated;
    // Les entrées d'un Map Dart gardent leur ordre d'insertion, donc les
    // premières sont bien les plus anciennes.
    if (map.length > _kMax) {
      for (final old in map.keys.take(map.length - _kMax).toList()) {
        map.remove(old);
      }
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(k, jsonEncode(map));
    } catch (e) {
      // Écriture ratée : la traduction reste valable pour cette session, elle
      // sera simplement redemandée à la prochaine ouverture.
      debugPrint('TranslationCache.put failed: $e');
    }
  }
}
