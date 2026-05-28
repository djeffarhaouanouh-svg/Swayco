import 'dart:math';

import 'package:flutter/material.dart';

import '../screens/call_screen.dart';
import '../translation/realtime_translation_port.dart';
import 'call_alert.dart';
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
  static Future<bool> startCall(
    BuildContext context, {
    required String peerDeviceId,
    required RealtimeTranslationPort translation,
  }) async {
    final myId = await DeviceId.getOrCreate();
    final localProfile = await UserPrefs.loadProfile();
    var myName = localProfile?.firstName.trim() ?? '';
    var mySourceLang = localProfile?.sourceLang.trim() ?? '';

    // Local prefs are empty on first sign-in from a new device — fall back
    // to the canonical Supabase profile row before giving up.
    if ((myName.isEmpty || mySourceLang.isEmpty) && isSupabaseReady) {
      final remote = await ProfileApi.fetchById(myId);
      if (remote != null) {
        if (myName.isEmpty) myName = remote.displayName.trim();
        if (mySourceLang.isEmpty) mySourceLang = remote.language.trim();
      }
    }

    try {
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
    }
  }
}
