import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Client for `scheduled_calls` (migration 0042). A caller proposes a
/// date/time; the backend cron fires a reminder push to both parties shortly
/// before it. The app only inserts/reads — the reminder itself is server-side.
abstract final class ScheduledCallApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Insert a planned call from [callerId] to [calleeId] at [when] (any tz;
  /// stored as UTC). Returns the row id on success or an error string.
  static Future<({String? id, String? error})> schedule({
    required String callerId,
    required String calleeId,
    required DateTime when,
  }) async {
    if (!isSupabaseReady) return (id: null, error: 'Supabase not configured');
    if (callerId.isEmpty || calleeId.isEmpty || callerId == calleeId) {
      return (id: null, error: 'Invalid caller/callee ids');
    }
    final authUid = _c.auth.currentUser?.id;
    if (authUid == null || authUid != callerId) {
      return (id: null, error: 'No session — reconnect.');
    }
    try {
      final inserted = await _c
          .from('scheduled_calls')
          .insert({
            'caller': callerId,
            'callee': calleeId,
            'scheduled_at': when.toUtc().toIso8601String(),
          })
          .select('id')
          .single();
      final id = Map<String, dynamic>.from(inserted)['id']?.toString();
      return (id: id, error: null);
    } catch (e) {
      debugPrint('[scheduled_call] insert failed: $e');
      return (id: null, error: e.toString());
    }
  }

  /// The soonest upcoming planned call between [myId] and [peerId] (either
  /// direction), or null if none is in the future. Returned in local time.
  static Future<DateTime?> nextUpcomingWith({
    required String myId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || myId.isEmpty || peerId.isEmpty) return null;
    try {
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final rows = await _c
          .from('scheduled_calls')
          .select('scheduled_at')
          .or('and(caller.eq.$myId,callee.eq.$peerId),'
              'and(caller.eq.$peerId,callee.eq.$myId)')
          .gt('scheduled_at', nowIso)
          .order('scheduled_at', ascending: true)
          .limit(1);
      if (rows.isEmpty) return null;
      final raw = rows.first['scheduled_at']?.toString();
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw)?.toLocal();
    } catch (e) {
      debugPrint('[scheduled_call] fetch failed: $e');
      return null;
    }
  }
}
