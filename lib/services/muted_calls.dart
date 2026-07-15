import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_id.dart';
import 'profile_api.dart';

/// People whose calls must NOT ring this phone. Muting is per-device and local
/// (like the chat "seen" pointers): the call still connects if you open it, the
/// phone just stays silent — no in-app ring dialog, no ringer notification.
///
/// The set is loaded once at boot into [ids] so any screen can read it
/// synchronously (the incoming-call handler can't await), and every change
/// writes through to SharedPreferences.
abstract final class MutedCalls {
  static const _key = 'muted_call_peers';

  /// The muted peer ids — kept in memory so a ringing check is synchronous.
  static final ValueNotifier<Set<String>> ids =
      ValueNotifier<Set<String>>(<String>{});

  /// Load the persisted set. Call once at startup.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    ids.value = (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  static bool isMuted(String peerId) =>
      peerId.isNotEmpty && ids.value.contains(peerId);

  static Future<void> setMuted(String peerId, bool muted) async {
    if (peerId.isEmpty) return;
    final next = {...ids.value};
    if (muted) {
      next.add(peerId);
    } else {
      next.remove(peerId);
    }
    ids.value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next.toList());
    // Mirror to the account so the backend skips the VoIP/CallKit push too.
    final myId = await DeviceId.getOrCreate();
    await ProfileApi.setCallMuted(myId: myId, peerId: peerId, muted: muted);
  }
}
