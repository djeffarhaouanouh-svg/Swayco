import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Tracks the count of pending friend requests addressed TO the local
/// user, so the Demandes tab can show a badge. A "request" is a row in
/// `friendships` where `addressee = meId` and `status = 'pending'`.
/// The count drops to zero as soon as the user accepts/rejects each row
/// from the Demandes screen — there is no separate "seen" timestamp.
abstract final class FriendRequestUnread {
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  static StreamSubscription<List<Map<String, dynamic>>>? _sub;
  static String _meId = '';

  /// Start watching `friendships` for [meId]. Safe to call repeatedly;
  /// re-subscribes if the id changed.
  static Future<void> start(String meId) async {
    if (meId.isEmpty || !isSupabaseReady) return;
    if (meId == _meId && _sub != null) return;
    _meId = meId;

    await _sub?.cancel();
    _sub = Supabase.instance.client
        .from('friendships')
        .stream(primaryKey: ['id'])
        .eq('addressee', meId)
        .listen(
          _onRows,
          onError: (e) =>
              debugPrint('FriendRequestUnread stream error: $e'),
        );
  }

  static void _onRows(List<Map<String, dynamic>> rows) {
    var n = 0;
    for (final r in rows) {
      if ((r['status']?.toString() ?? '') == 'pending') n++;
    }
    if (n != count.value) count.value = n;
  }

  /// Set the count directly — used by the Demandes screen right after
  /// an accept/reject so the badge updates without waiting for the
  /// realtime tick.
  static void setCount(int n) {
    if (n < 0) n = 0;
    if (n != count.value) count.value = n;
  }

  /// Tear-down on logout / device-id swap.
  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _meId = '';
    count.value = 0;
  }
}
