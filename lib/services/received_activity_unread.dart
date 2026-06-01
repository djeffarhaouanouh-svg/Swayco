import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'like_api.dart';
import 'supabase_service.dart';

/// Counts received "activity" the local user hasn't seen yet — likes on their
/// photos plus emoji photo-reactions — so the Demandes tab can badge it. The
/// "seen" point is a single timestamp in SharedPreferences; opening the
/// Demandes tab moves it to now via [markSeen].
///
/// Unlike friend requests (a pending queue tracked separately by
/// [FriendRequestUnread]), likes and reactions are fire-and-forget events, so
/// the badge is "how many arrived since I last looked". A plain periodic poll
/// keeps it fresh on every platform (the likes table / reaction messages
/// aren't worth a dedicated realtime subscription here).
abstract final class ReceivedActivityUnread {
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  static const _seenKey = 'demandes_activity_seen_iso';
  static const _pollInterval = Duration(seconds: 15);

  static String _meId = '';
  static DateTime _seenAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  static Timer? _poll;

  /// Start tracking for [meId]. Safe to call repeatedly. On the very first
  /// run (no stored timestamp) everything already received is treated as
  /// seen, so the badge only ever lights up for activity arriving from now on.
  static Future<void> start(String meId) async {
    if (meId.isEmpty || !isSupabaseReady) return;
    _meId = meId;

    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(_seenKey);
    if (iso != null) {
      _seenAt = DateTime.tryParse(iso)?.toUtc() ?? DateTime.now().toUtc();
    } else {
      _seenAt = DateTime.now().toUtc();
      await prefs.setString(_seenKey, _seenAt.toIso8601String());
    }

    await refresh();
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => refresh());
  }

  /// Re-count likes + reactions received since [_seenAt].
  static Future<void> refresh() async {
    if (_meId.isEmpty || !isSupabaseReady) return;
    try {
      final likes = await LikeApi.countReceivedLikesSince(_meId, _seenAt);
      final reactions = await ChatApi.countPhotoReactionsSince(_meId, _seenAt);
      final n = likes + reactions;
      if (count.value != n) count.value = n;
    } catch (e) {
      debugPrint('ReceivedActivityUnread.refresh failed: $e');
    }
  }

  /// Call when the user opens the Demandes tab — moves the seen pointer to
  /// now and clears the badge.
  static Future<void> markSeen() async {
    _seenAt = DateTime.now().toUtc();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_seenKey, _seenAt.toIso8601String());
    count.value = 0;
  }

  /// Tear-down on logout / device-id swap.
  static Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    _meId = '';
    count.value = 0;
  }
}
