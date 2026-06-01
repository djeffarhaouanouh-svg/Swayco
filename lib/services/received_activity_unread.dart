import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'like_api.dart';
import 'supabase_service.dart';

/// Counts received "activity" the local user hasn't seen yet — likes on their
/// photos plus emoji photo-reactions — so the Demandes tab can badge it.
///
/// Two timestamps, both seeded to "now" the first time the feature runs:
///   • [featureStartAt] — fixed; the Demandes list only shows likes / reactions
///     received AFTER this, so stale historical activity (e.g. an old like on a
///     photo that's since been deleted) never surfaces.
///   • the rolling "seen" pointer — the badge counts what arrived since it, and
///     [markSeen] pushes it to now when the user opens the tab.
///
/// A plain periodic poll keeps the count fresh on every platform.
abstract final class ReceivedActivityUnread {
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  static const _seenKey = 'demandes_activity_seen_iso';
  static const _startKey = 'demandes_activity_start_iso';
  static const _pollInterval = Duration(seconds: 15);

  static String _meId = '';
  static DateTime _seenAt = _epoch;
  static DateTime _featureStart = _epoch;
  static Timer? _poll;

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  /// The point from which received activity is considered "current". Likes /
  /// reactions older than this are pre-feature backlog and never shown.
  static DateTime get featureStartAt => _featureStart;

  /// Start tracking for [meId]. Safe to call repeatedly. On the very first run
  /// both timestamps are set to now, so neither the badge nor the Demandes
  /// list surfaces anything that arrived before the feature existed.
  static Future<void> start(String meId) async {
    if (meId.isEmpty || !isSupabaseReady) return;
    _meId = meId;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();

    final startIso = prefs.getString(_startKey);
    if (startIso != null) {
      _featureStart = DateTime.tryParse(startIso)?.toUtc() ?? now;
    } else {
      _featureStart = now;
      await prefs.setString(_startKey, now.toIso8601String());
    }

    final seenIso = prefs.getString(_seenKey);
    if (seenIso != null) {
      _seenAt = DateTime.tryParse(seenIso)?.toUtc() ?? _featureStart;
    } else {
      _seenAt = _featureStart;
      await prefs.setString(_seenKey, _seenAt.toIso8601String());
    }
    // Heal an old "epoch" pointer left by a previous build: the seen point
    // can never be earlier than when the feature started, otherwise the badge
    // would re-count the whole backlog.
    if (_seenAt.isBefore(_featureStart)) {
      _seenAt = _featureStart;
      await prefs.setString(_seenKey, _seenAt.toIso8601String());
    }

    await refresh();
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => refresh());
  }

  /// Re-count likes + reactions received since the rolling seen pointer.
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
  /// now and clears the badge. Does NOT touch [featureStartAt].
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
