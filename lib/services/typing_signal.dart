import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// "Is writing…" between the two sides of a DM: a Supabase Realtime
/// broadcast on `typing:<conversationId>` — ephemeral, no table, no row.
/// Joined while the thread is open on either side.
///
/// Missed messages are the norm on mobile (backgrounding, flaky network), so
/// the signal is self-healing: while I'm writing it re-announces itself every
/// [_heartbeat], and the peer's bubble expires on its own after [_expiry]
/// without news.
class TypingSignal {
  TypingSignal({
    required this.conversationId,
    required this.myId,
    required this.onPeerTyping,
  });

  final String conversationId;
  final String myId;

  /// Fires with `true` when the peer starts writing, `false` when they stop
  /// (or went silent for [_expiry]).
  final ValueChanged<bool> onPeerTyping;

  static const _heartbeat = Duration(seconds: 3);
  static const _expiry = Duration(seconds: 7);

  RealtimeChannel? _channel;
  Timer? _beat;
  Timer? _peerExpiry;
  bool _meTyping = false;
  bool _peerTyping = false;

  void start() {
    if (!isSupabaseReady || conversationId.isEmpty || myId.isEmpty) return;
    _channel = Supabase.instance.client
        .channel('typing:$conversationId')
        .onBroadcast(event: 'typing', callback: _onBroadcast);
    _channel!.subscribe();
  }

  void _onBroadcast(Map<String, dynamic> message) {
    final inner = message['payload'];
    final data = inner is Map ? inner : message;
    final user = data['user']?.toString() ?? '';
    if (user.isEmpty || user == myId) return;
    final typing = data['typing'] == true;
    _peerExpiry?.cancel();
    if (typing) _peerExpiry = Timer(_expiry, () => _setPeer(false));
    _setPeer(typing);
  }

  void _setPeer(bool typing) {
    if (typing == _peerTyping) return;
    _peerTyping = typing;
    onPeerTyping(typing);
  }

  /// My side: the composer is open / closed (or the message just went out).
  void setTyping(bool typing) {
    if (typing == _meTyping) return;
    _meTyping = typing;
    _beat?.cancel();
    _send(typing);
    if (typing) _beat = Timer.periodic(_heartbeat, (_) => _send(true));
  }

  void _send(bool typing) {
    final ch = _channel;
    if (ch != null) unawaited(_post(ch, typing));
  }

  Future<ChannelResponse> _post(RealtimeChannel ch, bool typing) =>
      ch.sendBroadcastMessage(
        event: 'typing',
        payload: {'user': myId, 'typing': typing},
      ).catchError((Object e) {
        debugPrint('TypingSignal send failed: $e');
        return ChannelResponse.error;
      });

  void dispose() {
    _beat?.cancel();
    _peerExpiry?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch == null) return;
    // Leaving mid-sentence: the "stopped" goes out BEFORE the channel does.
    final bye = _meTyping ? _post(ch, false) : Future.value(ChannelResponse.ok);
    unawaited(
      bye.whenComplete(() => Supabase.instance.client.removeChannel(ch)),
    );
  }
}
