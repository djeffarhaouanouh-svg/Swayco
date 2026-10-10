import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Liste d'attente des pays pas encore ouverts (globe : cadenas). Table et
/// fonction en base : migration 0069. Si elle n'est pas appliquée, ou hors
/// ligne, l'état local (par appareil) prend le relais — jamais d'erreur visible.
abstract final class CountryWaitlist {
  static const String _prefsKey = 'country_waitlist_mine';

  static Map<String, int>? _counts;
  static Set<String>? _mine;

  static SupabaseClient get _c => Supabase.instance.client;

  static Future<Set<String>> _readLocal() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(_prefsKey) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _writeLocal(Set<String> v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_prefsKey, v.toList());
    } catch (_) {}
  }

  /// Combien de personnes attendent chaque pays (clé GeoJSON -> n).
  static Future<Map<String, int>> counts() async {
    if (isSupabaseReady) {
      try {
        final r = await _c.rpc('country_waitlist_counts');
        if (r is List) {
          _counts = {
            for (final row in r)
              (row as Map)['country_key'].toString():
                  ((row['n'] as num?) ?? 0).toInt(),
          };
        }
      } catch (_) {}
    }
    return _counts ?? <String, int>{};
  }

  /// Les pays que J'attends.
  static Future<Set<String>> mine() async {
    if (isSupabaseReady) {
      try {
        final uid = _c.auth.currentUser?.id;
        if (uid != null) {
          final r = await _c
              .from('country_waitlist')
              .select('country_key')
              .eq('user_id', uid);
          _mine = {for (final row in r) row['country_key'].toString()};
          await _writeLocal(_mine!);
          return _mine!;
        }
      } catch (_) {}
    }
    return _mine ??= await _readLocal();
  }

  static Future<void> join(String key) async {
    final cur = {...(_mine ?? await _readLocal()), key};
    _mine = cur;
    await _writeLocal(cur);
    if (!isSupabaseReady) return;
    try {
      final uid = _c.auth.currentUser?.id;
      if (uid == null) return;
      await _c.from('country_waitlist').upsert({
        'user_id': uid,
        'country_key': key,
      }, onConflict: 'user_id,country_key');
    } catch (_) {}
  }

  static Future<void> leave(String key) async {
    final cur = {...(_mine ?? await _readLocal())}..remove(key);
    _mine = cur;
    await _writeLocal(cur);
    if (!isSupabaseReady) return;
    try {
      final uid = _c.auth.currentUser?.id;
      if (uid == null) return;
      await _c
          .from('country_waitlist')
          .delete()
          .eq('user_id', uid)
          .eq('country_key', key);
    } catch (_) {}
  }
}