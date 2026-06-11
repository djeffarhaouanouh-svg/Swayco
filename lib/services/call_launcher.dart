import 'dart:math';

import 'package:flutter/material.dart';

import '../screens/call_screen.dart';
import '../translation/realtime_translation_port.dart';
import 'call_alert.dart';
import 'call_credit_gate.dart';
import 'device_id.dart';
import 'incoming_call_api.dart';
import 'profile_api.dart';
import 'supabase_service.dart';
import 'token_api.dart';
import 'user_prefs.dart';

/// Single entry point that any screen can call to dial a friend. Wraps the
/// "derive deterministic room id from both device ids + mint LiveKit token
/// + push CallScreen" sequence so we don't duplicate it across the Chat
/// list, chat thread header, etc.
abstract final class CallLauncher {
  static String _newIdentity() {
    final r = Random();
    return 'u${DateTime.now().millisecondsSinceEpoch}${r.nextInt(999999)}';
  }

  /// The caller's identity for an outgoing call or guest invite: display
  /// name + spoken language, both needed for the translation route. Read
  /// local prefs first (instant, works offline) then fill any gap from the
  /// canonical Supabase profile row — the boot-time hydration in main.dart
  /// usually beats us to it, but this guarantees no call-site ever refuses
  /// an action just because local prefs were empty (fresh build install,
  /// hydration still in flight, or a prior network blip). Empty fields mean
  /// the profile is genuinely incomplete everywhere.
  ///
  /// Single source of truth — every screen that needs the caller's name +
  /// language MUST go through here instead of reading [UserPrefs.loadProfile]
  /// directly, so the local→remote fallback never has to be re-implemented
  /// (and drift) per call-site.
  static Future<MyCallIdentity> resolveMyIdentity() async {
    final local = await UserPrefs.loadProfile();
    var name = local?.firstName.trim() ?? '';
    var sourceLang = local?.sourceLang.trim() ?? '';
    if ((name.isEmpty || sourceLang.isEmpty) && isSupabaseReady) {
      final myId = await DeviceId.getOrCreate();
      final remote = await ProfileApi.fetchById(myId);
      if (remote != null) {
        if (name.isEmpty) name = remote.displayName.trim();
        if (sourceLang.isEmpty) sourceLang = remote.language.trim();
      }
    }
    return MyCallIdentity(name: name, sourceLang: sourceLang);
  }

  /// Deterministic LiveKit room name derived from both device ids. Sorted
  /// pair → both peers compute the same room. Trimmed to fit the backend's
  /// 3-64 char regex.
  static String roomNameFor(String idA, String idB) {
    final a = idA.replaceAll('-', '');
    final b = idB.replaceAll('-', '');
    final aShort = a.substring(0, a.length.clamp(0, 12));
    final bShort = b.substring(0, b.length.clamp(0, 12));
    final pair = [aShort, bShort]..sort();
    return 'call-${pair[0]}-${pair[1]}';
  }

  /// Returns true if the call was launched, false otherwise (missing profile,
  /// network error, etc.). Shows a snackbar on failure when [context] is
  /// still mounted.
  /// Lock so a double-tap on a call button (or two call entry points firing
  /// at once) can't start two calls / create two ring rows. Held until the
  /// call screen pops, then reset in the finally below.
  static bool _starting = false;

  static Future<bool> startCall(
    BuildContext context, {
    required String peerDeviceId,
    required RealtimeTranslationPort translation,
    bool startWithCamera = false,
  }) async {
    if (_starting) return false;
    _starting = true;
    try {
      final myId = await DeviceId.getOrCreate();
      final me = await resolveMyIdentity();
      final myName = me.name;
      final mySourceLang = me.sourceLang;

      // Péage: a credit-less caller can't place a call — but they can invite
      // the peer to call them back (free on their side, since the caller pays
      // the minutes). Fail-open on a failed read; the backend re-validates
      // credits on /livekit/token anyway.
      final myProfile = await ProfileApi.fetchById(myId);
      if (!CallCreditGate.canPlaceCall(myProfile)) {
        if (!context.mounted) return false;
        final peer = await ProfileApi.fetchById(peerDeviceId);
        if (!context.mounted) return false;
        await CallCreditGate.showAskToBeCalled(
          context,
          peerId: peerDeviceId,
          peerName: peer?.displayName ?? '',
          myId: myId,
          myName: myName,
        );
        return false;
      }

      final room = roomNameFor(myId, peerDeviceId);
      final token = await fetchLiveKitToken(
        roomName: room,
        identity: _newIdentity(),
        displayName: myName,
        sourceLang: mySourceLang,
      );
      // Fire a "ring" row so the callee's open tab gets a realtime push
      // to show the incoming-call modal. If this fails (RLS, FK, …) the
      // peer would be silently not-notified — surface a snackbar so the
      // caller knows their call isn't being announced.
      final ring = await IncomingCallApi.ring(
        callerId: myId,
        calleeId: peerDeviceId,
        roomName: token.roomName,
      );
      if (!context.mounted) return false;
      if (ring.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('La notif d\'appel a échoué : ${ring.error}'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      final ringId = ring.id;
      // Web-only outgoing dial tone — stops when CallScreen sees the
      // first remote join (callee picked up) or when CallScreen pops.
      CallAlert.startDialing();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            wsUrl: token.url,
            jwt: token.token,
            roomName: token.roomName,
            displayName: myName,
            mySourceLang: mySourceLang,
            translation: translation,
            isCaller: true,
            startWithCamera: startWithCamera,
            // Lets the waiting screen close itself the moment the callee
            // declines, instead of ringing into an empty room.
            outgoingCallId: ringId,
            // For the "call ended" summary card (peer PDP + flag).
            peerId: peerDeviceId,
          ),
        ),
      );
      // Defensive: in case CallScreen never saw a remote (declined /
      // unanswered), make sure the dial tone is silenced.
      CallAlert.stop();
      // Hangup / leave call → record the call's duration in-place so the
      // row survives as history (used to be a DELETE).
      if (ringId != null) {
        await IncomingCallApi.endCall(callId: ringId);
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossible de démarrer l\'appel : $e')),
        );
      }
      return false;
    } finally {
      _starting = false;
    }
  }
}

/// The caller's resolved name + spoken language for an outgoing call or
/// guest invite. Produced by [CallLauncher.resolveMyIdentity]. Empty fields
/// mean the profile is incomplete on both local prefs and Supabase.
class MyCallIdentity {
  const MyCallIdentity({required this.name, required this.sourceLang});

  final String name;
  final String sourceLang;

  /// True once both fields are present — the minimum to route translation.
  bool get isComplete => name.isNotEmpty && sourceLang.isNotEmpty;
}
