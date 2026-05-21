import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Tracks the count of unread messages addressed to the local user, so the
/// Chat tab can show a badge. The "seen" point is one timestamp stored in
/// SharedPreferences — opening the Chat list marks everything older as seen.
abstract final class ChatUnread {
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  static const _seenKey = 'chat_last_seen_iso';
  /// Prefix for per-conversation last-seen ISO timestamps. Each key looks
  /// like `chat_conv_seen_<conversationId>` and is bumped when the user
  /// actually opens that thread — independent from the global `_seenKey`
  /// which only drives the chat-tab unread badge.
  static const _convSeenPrefix = 'chat_conv_seen_';
  static StreamSubscription<List<Map<String, dynamic>>>? _sub;
  static String _meId = '';
  static String _lastSeenIso = '';

  /// Start watching the messages table for [meId]. Safe to call repeatedly;
  /// re-subscribes if the id changed.
  static Future<void> start(String meId) async {
    if (meId.isEmpty || !isSupabaseReady) return;
    if (meId == _meId && _sub != null) return;
    _meId = meId;

    final prefs = await SharedPreferences.getInstance();
    _lastSeenIso = prefs.getString(_seenKey) ??
        DateTime.now().toUtc().toIso8601String();

    await _sub?.cancel();
    _sub = Supabase.instance.client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('recipient', meId)
        .listen(
          _onRows,
          onError: (e) =>
              debugPrint('ChatUnread stream error: $e'),
        );
  }

  static void _onRows(List<Map<String, dynamic>> rows) {
    var n = 0;
    for (final r in rows) {
      final ts = r['created_at']?.toString() ?? '';
      if (ts.isNotEmpty && ts.compareTo(_lastSeenIso) > 0) {
        n++;
      }
    }
    if (count.value != n) count.value = n;
  }

  /// Call when the user opens the Chat tab — moves the seen pointer to now
  /// and resets the badge.
  static Future<void> markAllSeen() async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    _lastSeenIso = nowIso;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_seenKey, nowIso);
    count.value = 0;
  }

  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _meId = '';
    count.value = 0;
  }

  /// Mark conversation [convId] as seen *now*. Called when its thread is
  /// opened so the per-row unread indicator on the chat list clears for
  /// that specific row.
  static Future<void> markConversationSeen(String convId) async {
    if (convId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      '$_convSeenPrefix$convId',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Snapshot of every per-conversation last-seen timestamp. Returned as
  /// a `{conversationId: DateTime}` map; conversations the user has never
  /// opened are simply absent from the map (callers should treat that as
  /// "everything is unread").
  static Future<Map<String, DateTime>> readPerConversationSeen() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, DateTime>{};
    for (final k in p.getKeys()) {
      if (!k.startsWith(_convSeenPrefix)) continue;
      final iso = p.getString(k);
      if (iso == null) continue;
      final dt = DateTime.tryParse(iso);
      if (dt == null) continue;
      out[k.substring(_convSeenPrefix.length)] = dt;
    }
    return out;
  }

  /// Prefix for per-conversation "cleared at" timestamps — set when the
  /// user deletes a conversation from their chat list. Local-only (delete
  /// for me): the peer's copy is untouched.
  static const _convClearedPrefix = 'chat_conv_cleared_';

  /// Mark conversation [convId] as cleared *now*. The chat list hides it
  /// until a message newer than this timestamp arrives.
  static Future<void> markConversationCleared(String convId) async {
    if (convId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      '$_convClearedPrefix$convId',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Snapshot of every "cleared at" timestamp, `{conversationId: DateTime}`.
  static Future<Map<String, DateTime>> clearedConversations() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, DateTime>{};
    for (final k in p.getKeys()) {
      if (!k.startsWith(_convClearedPrefix)) continue;
      final iso = p.getString(k);
      if (iso == null) continue;
      final dt = DateTime.tryParse(iso);
      if (dt == null) continue;
      out[k.substring(_convClearedPrefix.length)] = dt;
    }
    return out;
  }
}
