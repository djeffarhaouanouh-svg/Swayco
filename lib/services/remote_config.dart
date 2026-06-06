import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Dashboard-editable remote config (Supabase `app_config` table). Fetched once
/// at boot and cached. Lets features be toggled remotely with no app update —
/// the remote kill-switch (e.g. the "X online" badge can be turned off in
/// seconds if Apple review objects). Degrades to fallbacks when Supabase is
/// unreachable, so nothing breaks if the fetch fails.
abstract final class RemoteConfig {
  static final Map<String, String> _cache = {};

  /// Bumped after every successful [load] so widgets can rebuild when the
  /// config arrives (the first frame may render before the fetch resolves).
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static Future<void> load() async {
    if (!isSupabaseReady) return;
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value');
      _cache.clear();
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        _cache[m['key'].toString()] = m['value'].toString();
      }
      version.value++;
    } catch (e) {
      debugPrint('RemoteConfig.load failed: $e');
    }
  }

  static String? str(String key) => _cache[key];

  static bool flag(String key, {bool fallback = false}) {
    final v = _cache[key];
    if (v == null) return fallback;
    return v == '1' || v.toLowerCase() == 'true';
  }

  static int integer(String key, int fallback) =>
      int.tryParse(_cache[key] ?? '') ?? fallback;
}
