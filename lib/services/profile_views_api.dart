import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'block_api.dart';
import 'profile_api.dart';
import 'supabase_service.dart';

/// Une personne qui a ouvert mon profil, et quand pour la dernière fois.
typedef ProfileView = ({RemoteProfile profile, DateTime at});

/// Les vues de profil (table `profile_views`, migration 0099).
abstract final class ProfileViewsApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// J'ai ouvert le profil de [peerId]. Une ligne par jour, sans jamais gêner
  /// la page : un échec est ignoré.
  static Future<void> record(String peerId) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty || peerId.isEmpty || me == peerId) {
      return;
    }
    try {
      await ProfileApi.ensureMyProfileRow();
      await _c.from('profile_views').upsert(
        {'viewed_id': peerId, 'viewer_id': me},
        onConflict: 'viewed_id,viewer_id,day',
        ignoreDuplicates: true,
      );
    } catch (e) {
      debugPrint('ProfileViewsApi.record failed: $e');
    }
  }

  /// Qui a vu mon profil ces 7 derniers jours, le plus récent d'abord, une fois
  /// par personne, sans les personnes bloquées. Lève en cas d'échec.
  static Future<List<ProfileView>> thisWeek() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return const [];
    final since = DateTime.now().toUtc().subtract(const Duration(days: 7));
    final rows = await _c
        .from('profile_views')
        .select('viewer_id, viewed_at')
        .eq('viewed_id', me)
        .gte('viewed_at', since.toIso8601String())
        .order('viewed_at', ascending: false)
        .limit(500);
    final last = <String, DateTime>{};
    for (final r in rows as List) {
      final m = Map<String, dynamic>.from(r as Map);
      final id = m['viewer_id']?.toString() ?? '';
      final at = DateTime.tryParse(m['viewed_at']?.toString() ?? '');
      if (id.isEmpty || at == null) continue;
      last.putIfAbsent(id, () => at.toLocal());
    }
    if (last.isEmpty) return const [];
    final results = await Future.wait<Object>([
      ProfileApi.fetchByIds(last.keys.toList()),
      BlockApi.fetchMyBlockedProfiles(me),
      BlockApi.fetchMyBlockerIds(),
    ]);
    final byId = {
      for (final p in results[0] as List<RemoteProfile>) p.id: p,
    };
    final hidden = {
      for (final p in results[1] as List<RemoteProfile>) p.id,
      ...results[2] as Set<String>,
    };
    return [
      for (final e in last.entries)
        if (byId[e.key] != null && !hidden.contains(e.key))
          (profile: byId[e.key]!, at: e.value),
    ];
  }

  static String _seenKey() =>
      'profile_views_seen_${AuthService.currentUserId}';

  /// La dernière fois que j'ai ouvert la liste (pour la pastille « nouveaux »).
  static Future<DateTime> lastSeen() async {
    final p = await SharedPreferences.getInstance();
    return DateTime.fromMillisecondsSinceEpoch(p.getInt(_seenKey()) ?? 0);
  }

  static Future<void> markSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_seenKey(), DateTime.now().millisecondsSinceEpoch);
  }
}
