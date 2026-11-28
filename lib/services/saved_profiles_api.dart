import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'block_api.dart';
import 'profile_api.dart';
import 'supabase_service.dart';

/// Les profils enregistrés avec le marque-page (table `saved_profiles`,
/// migration 0098). Privés : on ne voit que les siens.
abstract final class SavedProfilesApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Change à chaque ajout / retrait : la page « Profils enregistrés » suit.
  static final revision = ValueNotifier<int>(0);

  static Future<bool> isSaved(String peerId) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty || peerId.isEmpty) return false;
    try {
      final row = await _c
          .from('saved_profiles')
          .select('saved_id')
          .eq('owner_id', me)
          .eq('saved_id', peerId)
          .maybeSingle();
      return row != null;
    } catch (e) {
      debugPrint('SavedProfilesApi.isSaved failed: $e');
      return false;
    }
  }

  /// Lève en cas d'échec : le bouton revient alors à son état d'avant.
  static Future<void> setSaved(String peerId, bool saved) async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty || peerId.isEmpty || me == peerId) {
      throw StateError('saved profile: not signed in');
    }
    if (saved) {
      await ProfileApi.ensureMyProfileRow();
      await _c.from('saved_profiles').upsert(
        {'owner_id': me, 'saved_id': peerId},
        onConflict: 'owner_id,saved_id',
        ignoreDuplicates: true,
      );
    } else {
      await _c
          .from('saved_profiles')
          .delete()
          .eq('owner_id', me)
          .eq('saved_id', peerId);
    }
    revision.value++;
  }

  /// Mes profils enregistrés, le plus récent d'abord, sans les personnes
  /// bloquées (dans un sens ou l'autre). Lève en cas d'échec.
  static Future<List<RemoteProfile>> fetch() async {
    final me = AuthService.currentUserId;
    if (!isSupabaseReady || me.isEmpty) return const [];
    final rows = await _c
        .from('saved_profiles')
        .select('saved_id')
        .eq('owner_id', me)
        .order('created_at', ascending: false);
    final ids = [
      for (final r in rows as List)
        Map<String, dynamic>.from(r as Map)['saved_id'].toString(),
    ];
    if (ids.isEmpty) return const [];
    final results = await Future.wait<Object>([
      ProfileApi.fetchByIds(ids),
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
      for (final id in ids)
        if (byId[id] != null && !hidden.contains(id)) byId[id]!,
    ];
  }
}
