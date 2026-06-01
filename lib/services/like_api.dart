import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';

/// Read/write helpers for the `likes` table:
///
/// ```sql
/// create table likes (
///   liker uuid not null references auth.users(id) on delete cascade,
///   liked uuid not null references auth.users(id) on delete cascade,
///   created_at timestamptz not null default now(),
///   primary key (liker, liked)
/// );
/// alter table likes enable row level security;
/// alter publication supabase_realtime add table likes;
/// create policy "users insert their own likes"
///   on likes for insert to authenticated with check (auth.uid() = liker);
/// create policy "users delete their own likes"
///   on likes for delete to authenticated using (auth.uid() = liker);
/// create policy "users read likes that involve them"
///   on likes for select to authenticated
///   using (auth.uid() = liker or auth.uid() = liked);
/// ```
///
/// One-directional: liking someone is unilateral and visible to that
/// person via [fetchLikersOf]. There is no matching mechanic.
abstract final class LikeApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Idempotent — re-liking the same person is a no-op via the composite PK.
  static Future<void> like({
    required String likerId,
    required String likedId,
  }) async {
    if (!isSupabaseReady) return;
    if (likerId.isEmpty || likedId.isEmpty || likerId == likedId) return;
    try {
      await _c.from('likes').upsert({
        'liker': likerId,
        'liked': likedId,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'liker,liked');
      unawaited(_notifyLike(likerId, likedId));
    } catch (e) {
      debugPrint('LikeApi.like failed: $e');
      rethrow;
    }
  }

  static Future<void> _notifyLike(String likerId, String likedId) async {
    try {
      final likerProfile = await ProfileApi.fetchById(likerId);
      final likerName = likerProfile?.displayName.trim() ?? '';
      await PushDispatcher.notify(
        recipientUid: likedId,
        title: likerName.isEmpty ? 'Nouveau like ❤' : likerName,
        body: 'a aimé ton profil ❤',
        type: 'like',
        data: {'likerId': likerId},
      );
    } catch (e) {
      debugPrint('like notify failed: $e');
    }
  }

  /// Remove the like row. Safe to call when no row exists.
  static Future<void> unlike({
    required String likerId,
    required String likedId,
  }) async {
    if (!isSupabaseReady || likerId.isEmpty || likedId.isEmpty) return;
    try {
      await _c.from('likes').delete().eq('liker', likerId).eq('liked', likedId);
    } catch (e) {
      debugPrint('LikeApi.unlike failed: $e');
      rethrow;
    }
  }

  /// Set of profile ids I've liked — used by Discover to render the
  /// heart in its filled state for profiles I previously liked.
  static Future<Set<String>> fetchMyLikedIds(String likerId) async {
    if (!isSupabaseReady || likerId.isEmpty) return const <String>{};
    try {
      final rows = await _c.from('likes').select('liked').eq('liker', likerId);
      return (rows as List)
          .map(
            (r) =>
                Map<String, dynamic>.from(r as Map)['liked']?.toString() ?? '',
          )
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (e) {
      debugPrint('LikeApi.fetchMyLikedIds failed: $e');
      return const <String>{};
    }
  }

  /// Hydrated list of profiles that have liked [userId], newest first.
  /// Powers the "qui m'a liké" screen.
  static Future<List<RemoteProfile>> fetchLikersOf(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return const [];
    try {
      final rows = await _c
          .from('likes')
          .select('liker, created_at')
          .eq('liked', userId)
          .order('created_at', ascending: false);
      final ids = (rows as List)
          .map(
            (r) =>
                Map<String, dynamic>.from(r as Map)['liker']?.toString() ?? '',
          )
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (ids.isEmpty) return const [];
      return ProfileApi.fetchByIds(ids);
    } catch (e) {
      debugPrint('LikeApi.fetchLikersOf failed: $e');
      return const [];
    }
  }

  /// Wipe every like row pointing at the current auth user. Called when
  /// the user deletes their Discover photo so the heart badge — which
  /// represents likes received on that photo — doesn't linger over an
  /// empty cell.
  ///
  /// Goes through the `delete_my_received_likes` SECURITY DEFINER RPC
  /// because the table-level RLS only authorises the *liker* to delete a
  /// row; the *liked* party can't, even for their own received likes. The
  /// RPC derives the target id from `auth.uid()` server-side so it can
  /// only ever wipe the caller's own rows.
  ///
  /// `userId` is kept in the signature for caller convenience / clarity
  /// but isn't actually sent — see the function definition.
  static Future<void> deleteAllLikersOf(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return;
    try {
      await _c.rpc('delete_my_received_likes');
    } catch (e) {
      debugPrint('LikeApi.deleteAllLikersOf failed: $e');
      rethrow;
    }
  }

  /// Batched count of `received likes` for a list of profile ids.
  /// Calls the `received_likes_counts` SECURITY DEFINER RPC (migration
  /// 0027) so a single round-trip yields the popularity metric for
  /// every Discover candidate. Used by the feed scorer to boost
  /// profiles that already have traction. Returns a map keyed by id;
  /// ids absent from the result map have zero likes.
  static Future<Map<String, int>> countLikersOfMany(
    List<String> userIds,
  ) async {
    if (!isSupabaseReady || userIds.isEmpty) return const {};
    try {
      final result = await _c.rpc(
        'received_likes_counts',
        params: {'p_ids': userIds},
      );
      if (result is! List) return const {};
      final out = <String, int>{};
      for (final row in result) {
        final m = Map<String, dynamic>.from(row as Map);
        final id = m['liked']?.toString() ?? '';
        final n = (m['n'] as num?)?.toInt() ?? 0;
        if (id.isNotEmpty) out[id] = n;
      }
      return out;
    } catch (e) {
      debugPrint('LikeApi.countLikersOfMany failed: $e');
      return const {};
    }
  }

  /// Quick count for the badge on the profile screen.
  static Future<int> countLikersOf(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return 0;
    try {
      final rows = await _c.from('likes').select('liker').eq('liked', userId);
      return (rows as List).length;
    } catch (e) {
      debugPrint('LikeApi.countLikersOf failed: $e');
      return 0;
    }
  }

  /// Count of likes received by [userId] strictly after [since] — drives the
  /// "new activity" badge on the Demandes tab so a fresh like lights it up.
  static Future<int> countReceivedLikesSince(
    String userId,
    DateTime since,
  ) async {
    if (!isSupabaseReady || userId.isEmpty) return 0;
    try {
      final rows = await _c
          .from('likes')
          .select('liker')
          .eq('liked', userId)
          .gt('created_at', since.toUtc().toIso8601String());
      return (rows as List).length;
    } catch (e) {
      debugPrint('LikeApi.countReceivedLikesSince failed: $e');
      return 0;
    }
  }
}
