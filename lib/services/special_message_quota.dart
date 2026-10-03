import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Messages spéciaux (Discover, bouton doré) : [total] à vie pour les
/// abonnés Premium. Le compteur vit en base (migration 0063, fonctions
/// `special_messages_remaining` / `consume_special_message`) ; si elle n'est
/// pas encore appliquée, repli sur un compteur local par compte.
abstract final class SpecialMessageQuota {
  static const int total = 3;

  static Future<int> _localUsed(SharedPreferences p, String uid) async {
    return p.getInt('special_msg_used_$uid') ?? 0;
  }

  /// Messages spéciaux qu'il reste à envoyer (3 → 0).
  static Future<int> remaining(String uid) async {
    if (isSupabaseReady) {
      try {
        final r = await Supabase.instance.client
            .rpc('special_messages_remaining');
        if (r is num) return r.toInt().clamp(0, total);
      } catch (_) {}
    }
    try {
      final p = await SharedPreferences.getInstance();
      final left = total - await _localUsed(p, uid);
      return left < 0 ? 0 : left;
    } catch (_) {
      return total;
    }
  }

  /// À appeler une fois le message parti : en retire un.
  static Future<void> consume(String uid) async {
    if (isSupabaseReady) {
      try {
        await Supabase.instance.client.rpc('consume_special_message');
        return;
      } catch (_) {}
    }
    try {
      final p = await SharedPreferences.getInstance();
      final used = await _localUsed(p, uid);
      await p.setInt('special_msg_used_$uid', used + 1);
    } catch (_) {}
  }
}
