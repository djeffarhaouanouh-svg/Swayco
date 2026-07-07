import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';

/// One pending incoming call as seen by the callee. The room name is what
/// the callee should connect to via LiveKit if they accept.
class IncomingCall {
  const IncomingCall({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.roomName,
    required this.createdAt,
  });

  final String id;
  final String callerId;
  final String calleeId;
  final String roomName;
  final DateTime createdAt;

  factory IncomingCall.fromMap(Map<String, dynamic> m) => IncomingCall(
        id: m['id']?.toString() ?? '',
        callerId: m['caller']?.toString() ?? '',
        calleeId: m['callee']?.toString() ?? '',
        roomName: m['room_name']?.toString() ?? '',
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '')
                ?.toLocal() ??
            DateTime.now(),
      );
}

/// Realtime ring/answer over Supabase. Schema:
///
/// ```sql
/// create table incoming_calls (
///   id uuid primary key default gen_random_uuid(),
///   caller uuid not null references auth.users(id) on delete cascade,
///   callee uuid not null references auth.users(id) on delete cascade,
///   room_name text not null,
///   created_at timestamptz not null default now()
/// );
/// alter table incoming_calls enable row level security;
/// alter publication supabase_realtime add table incoming_calls;
///
/// create policy "callee can see their own incoming calls"
///   on incoming_calls for select using (auth.uid() = callee);
/// create policy "caller can insert their own outgoing calls"
///   on incoming_calls for insert with check (auth.uid() = caller);
/// create policy "caller or callee can delete"
///   on incoming_calls for delete using (
///     auth.uid() = caller or auth.uid() = callee
///   );
/// ```
abstract final class IncomingCallApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Result of [ring] — exposes the inserted row id on success and the
  /// raw Postgres error on failure so the caller can surface it in the
  /// UI (RLS violations, FK errors, etc. used to be lost in debug logs).
  ///
  /// Either [id] is non-null, or [error] is non-null. Never both.
  static ({String? id, String? error}) _ringResult({String? id, String? error}) =>
      (id: id, error: error);

  /// Inserts a fresh "ringing" row addressed to [calleeId]. The callee's
  /// realtime subscription will pick it up and show the incoming-call
  /// modal. Returns the inserted row id on success, or an error string
  /// describing why the insert failed (RLS, FK, network, …).
  ///
  /// Pre-flight: refuses to even hit the INSERT when the local Supabase
  /// auth state would obviously cause an RLS rejection — no session, or
  /// a [callerId] that doesn't match the JWT's `sub`. Saves a round-trip
  /// and surfaces a concrete reason instead of the generic
  /// "new row violates row-level security policy" Postgres returns.
  static Future<({String? id, String? error})> ring({
    required String callerId,
    required String calleeId,
    required String roomName,
  }) async {
    if (!isSupabaseReady) {
      return _ringResult(error: 'Supabase not configured');
    }
    if (callerId.isEmpty || calleeId.isEmpty || callerId == calleeId) {
      return _ringResult(error: 'Invalid caller/callee ids');
    }
    final session = _c.auth.currentSession;
    final authUid = _c.auth.currentUser?.id;
    if (session == null || authUid == null || authUid.isEmpty) {
      debugPrint('[ring] no auth session → aborting pre-flight');
      return _ringResult(
        error: 'Pas de session — déconnecte-toi puis reconnecte.',
      );
    }
    if (authUid != callerId) {
      debugPrint(
        '[ring] callerId mismatch: arg=$callerId vs auth.uid=$authUid',
      );
      return _ringResult(
        error:
            'ID désynchronisé : callerId=$callerId ≠ auth.uid=$authUid. '
            'Reconnecte-toi.',
      );
    }
    try {
      // The ring row FK-references my profiles row; self-heal it first so a
      // launch that skipped the profile sync doesn't 23503 here too.
      await ProfileApi.ensureMyProfileRow();
      final inserted = await _c
          .from('incoming_calls')
          .insert({
            'caller': callerId,
            'callee': calleeId,
            'room_name': roomName,
          })
          .select('id')
          .single();
      final id = Map<String, dynamic>.from(inserted)['id']?.toString();
      debugPrint('[ring] inserted incoming_call id=$id callee=$calleeId');
      unawaited(_notifyRing(
        callerId: callerId,
        calleeId: calleeId,
        callId: id ?? '',
        roomName: roomName,
      ));
      return _ringResult(id: id);
    } catch (e) {
      debugPrint('[ring] FAILED (auth.uid=$authUid caller=$callerId): $e');
      return _ringResult(error: e.toString());
    }
  }

  static Future<void> _notifyRing({
    required String callerId,
    required String calleeId,
    required String callId,
    required String roomName,
  }) async {
    try {
      final caller = await ProfileApi.fetchById(callerId);
      final callerName = caller?.displayName.trim() ?? '';
      // Localise into the CALLEE's language — they shouldn't get "Appel
      // entrant" in French just because the caller's app is in French.
      final callee = await ProfileApi.fetchById(calleeId);
      final lang = callee?.language ?? '';
      await PushDispatcher.notify(
        recipientUid: calleeId,
        title: callerName.isEmpty
            ? AppStrings.tIn(lang, 'push_incoming_call_title')
            : callerName,
        body: AppStrings.tIn(lang, 'push_incoming_call_body'),
        type: 'incoming_call',
        data: {
          'callId': callId,
          'callerId': callerId,
          'roomName': roomName,
        },
      );
    } catch (e) {
      debugPrint('ring notify failed: $e');
    }
  }

  /// One-shot lookup of every still-ringing row addressed to [calleeId].
  /// Used as a polling backup on the web build where the realtime
  /// websocket subscription isn't always reliable (browser throttling,
  /// network hiccups). Filters out historical rows (ended_at is not null)
  /// so old calls don't keep re-triggering the modal.
  static Future<List<IncomingCall>> fetchPending(String calleeId) async {
    if (!isSupabaseReady || calleeId.isEmpty) return const [];
    try {
      // Only fresh rings: a row older than the caller's ring window is a
      // missed/abandoned call (the caller may have closed the tab without
      // stamping ended_at), so it must not re-pop the answer UI on app open.
      final cutoff = DateTime.now()
          .toUtc()
          .subtract(const Duration(seconds: 45))
          .toIso8601String();
      final rows = await _c
          .from('incoming_calls')
          .select()
          .eq('callee', calleeId)
          .filter('ended_at', 'is', null)
          .gte('created_at', cutoff);
      return (rows as List)
          .map((r) => IncomingCall.fromMap(Map<String, dynamic>.from(r as Map)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('IncomingCallApi.fetchPending failed: $e');
      return const [];
    }
  }

  /// Fetch one call row by id. Used on the iOS CallKit "accept" path: the
  /// accept event only carries the call id, so we read the row back to get
  /// the room name to join. RLS lets the callee (and caller) read it.
  static Future<IncomingCall?> fetchById(String callId) async {
    if (!isSupabaseReady || callId.isEmpty) return null;
    try {
      // Bounded: this sits on the iOS CallKit "accept" fallback path (when
      // the native push payload didn't carry the room name) — an unbounded
      // await here left CallKit "connected" with the app never landing on
      // the call screen if networking was still flaky right after a
      // cold-launch wake.
      final row = await _c
          .from('incoming_calls')
          .select()
          .eq('id', callId)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      if (row == null) return null;
      return IncomingCall.fromMap(Map<String, dynamic>.from(row));
    } catch (e) {
      debugPrint('IncomingCallApi.fetchById failed: $e');
      return null;
    }
  }

  /// Marks a ringing row as ended via the `end_incoming_call` RPC, which
  /// stamps `ended_at = now()` and records the elapsed duration in
  /// `duration_seconds`. Replaces the old hard-DELETE so the row
  /// survives as call history.
  ///
  /// Both caller (cancel before pickup) and callee (decline / accept)
  /// can call this — the SQL function does the authorisation check.
  static Future<void> endCall({required String callId}) async {
    if (!isSupabaseReady || callId.isEmpty) return;
    try {
      await _c.rpc('end_incoming_call', params: {'p_call_id': callId});
    } catch (e) {
      debugPrint('IncomingCallApi.endCall failed: $e');
    }
  }

  /// Backwards-compatible alias. The semantic shifted from "delete the
  /// row" to "stamp ended_at" but the call sites still want a single
  /// "ring is over" hook.
  static Future<void> cancel({required String callId}) =>
      endCall(callId: callId);

  /// Callee-side: tell the caller their ring [callId] was declined so the
  /// caller's waiting screen can close instead of sitting on an empty
  /// room. Fires a one-off broadcast on a per-call channel. We can't
  /// reuse the `ended_at` DB stamp for this because the *accept* path
  /// also stamps it (just before the callee joins LiveKit), so it
  /// wouldn't distinguish "declined" from "accepted". Best-effort —
  /// `sendBroadcastMessage` falls back to the REST endpoint when the
  /// channel isn't joined, so no explicit subscribe is needed here.
  static Future<void> broadcastDecline({required String callId}) async {
    if (!isSupabaseReady || callId.isEmpty) return;
    try {
      final channel = _c.channel('call-decline:$callId');
      await channel.sendBroadcastMessage(
        event: 'declined',
        payload: const {},
      );
      await _c.removeChannel(channel);
    } catch (e) {
      debugPrint('IncomingCallApi.broadcastDecline failed: $e');
    }
  }

  /// Caller-side counterpart to [broadcastDecline]: subscribe to the
  /// per-call channel and fire [onDeclined] when the callee declines the
  /// ring [callId]. Returns the channel so the caller can remove it when
  /// the call screen tears down.
  static RealtimeChannel subscribeDecline({
    required String callId,
    required void Function() onDeclined,
  }) {
    final channel = _c.channel('call-decline:$callId').onBroadcast(
          event: 'declined',
          callback: (_) => onDeclined(),
        );
    channel.subscribe();
    return channel;
  }

  /// Caller-side: tell the callee we gave up on ring [callId] BEFORE they
  /// answered (hung up while waiting, or the ring timed out) so their phone
  /// stops ringing immediately instead of waiting out its local ~30 s
  /// dialog / CallKit timeout. Symmetric to [broadcastDecline]. Best-effort
  /// — `sendBroadcastMessage` REST-falls-back when the channel isn't joined.
  static Future<void> broadcastCancel({required String callId}) async {
    if (!isSupabaseReady || callId.isEmpty) return;
    try {
      final channel = _c.channel('call-cancel:$callId');
      await channel.sendBroadcastMessage(
        event: 'cancelled',
        payload: const {},
      );
      await _c.removeChannel(channel);
    } catch (e) {
      debugPrint('IncomingCallApi.broadcastCancel failed: $e');
    }
  }

  /// Callee-side counterpart to [broadcastCancel]: subscribe to the per-call
  /// channel and fire [onCancelled] when the caller cancels the ring
  /// [callId] before pickup. Returns the channel so the callee can remove it
  /// once the ring UI closes.
  static RealtimeChannel subscribeCancel({
    required String callId,
    required void Function() onCancelled,
  }) {
    final channel = _c.channel('call-cancel:$callId').onBroadcast(
          event: 'cancelled',
          callback: (_) => onCancelled(),
        );
    channel.subscribe();
    return channel;
  }

  /// Subscribe to incoming-call rows for [calleeId]. The returned channel
  /// must be `unsubscribe()`d when the listener tears down (e.g. on sign
  /// out). [onCall] fires for every fresh INSERT.
  static RealtimeChannel subscribe({
    required String calleeId,
    required void Function(IncomingCall) onCall,
  }) {
    debugPrint('[ring] subscribing as callee=$calleeId');
    final channel = _c.channel('incoming_calls:$calleeId').onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'incoming_calls',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'callee',
            value: calleeId,
          ),
          callback: (payload) {
            debugPrint('[ring] received realtime insert: ${payload.newRecord}');
            final row = payload.newRecord;
            onCall(IncomingCall.fromMap(Map<String, dynamic>.from(row)));
          },
        );
    channel.subscribe((status, error) {
      debugPrint('[ring] channel status=$status err=$error');
    });
    return channel;
  }
}
