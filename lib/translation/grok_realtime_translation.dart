import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/translation_api.dart';
import 'grok_mic_streamer_base.dart';
import 'grok_mic_streamer_io.dart'
    if (dart.library.js_interop) 'grok_mic_streamer_web.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// Realtime Grok translation, SENDER-side. Each phone captures its OWN mic (web:
/// getUserMedia + MediaStreamTrackProcessor; native: record), streams it to the
/// xAI realtime STT WS, translates MY outgoing voice INTO the peer's language,
/// and pushes the Grok voice to the peer over the data channel (voice-only, no
/// subtitle). The peer just plays it (call_screen `voiceOnly` branch). Capturing
/// the LOCAL mic — not the remote track — is what makes this work on iOS, where
/// tapping the remote WebRTC audio is impossible.
class GrokRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  /// Must match call_screen's `_captionTopic`.
  static const String _captionTopic = 'swayco-chat';
  static const int _maxAudioB64 = 60000;

  Room? _room;
  TranslationRoute? _route;
  GrokMicStreamer? _streamer;

  int _sent = 0;
  String? _lastTranscript;
  String? _lastTranslation;
  String? _lastError;

  @override
  Listenable? get translationListenable => this;

  @override
  Widget? buildTranslationAudioOverlay() => null;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase {
    if (_room == null || _route == null || !_route!.isConfigured) {
      return TranslationFeedbackPhase.hidden;
    }
    final s = _streamer;
    if (s == null) return TranslationFeedbackPhase.standby;
    return s.isStreaming
        ? TranslationFeedbackPhase.live
        : TranslationFeedbackPhase.working;
  }

  @override
  bool get translationRemoteVoiceHot => false;

  @override
  bool get translationSpeaking => false;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {}

  @override
  String get translationDiagnostics {
    final route = _route;
    final routeLabel = route == null
        ? 'NULL'
        : (!route.isConfigured
            ? 'NON-CONFIG'
            : '${route.sourceBcp47}→${route.targetBcp47}');
    final s = _streamer;
    final state = s == null ? 'inactif' : (s.isStreaming ? 'micro→STT' : '…');
    final lines = <String>[
      'Grok RT(TEST): $state • route: $routeLabel • envois: $_sent',
    ];
    if (_lastTranscript != null) lines.add('STT: $_lastTranscript');
    if (_lastTranslation != null) lines.add('TRAD: $_lastTranslation');
    if (_lastError != null) lines.add('ERR: $_lastError');
    return lines.join('\n');
  }

  @override
  Future<void> attachToRoom(Room room, {required TranslationRoute route}) async {
    await detach();
    _room = room;
    _route = route;
    debugPrint('[grok-rt] attach src=${route.sourceBcp47} tgt=${route.targetBcp47}');
    if (!route.isConfigured) return;

    // Sender-side route: from = MY language (what I speak), to = the peer's.
    final wsUrl = grokSttWsUri(
      from: route.sourceBcp47,
      to: route.targetBcp47,
    );
    final streamer = createGrokMicStreamer();
    _streamer = streamer;
    try {
      await streamer.start(
        wsUrl: wsUrl,
        localTrack: _localMicTrack(room),
        onTranslation: _onTranslation,
        onPartial: (_) {},
        onError: (code) {
          _lastError = code;
          notifyListeners();
        },
      );
    } catch (e) {
      _lastError = 'start: $e';
    }
    notifyListeners();
  }

  /// The LiveKit local mic track (native streamer forks it; web uses its own
  /// getUserMedia and ignores it).
  MediaStreamTrack? _localMicTrack(Room room) {
    for (final pub in room.localParticipant?.audioTrackPublications ?? const []) {
      final t = pub.track;
      if (t is LocalAudioTrack) return t.mediaStreamTrack;
    }
    return null;
  }

  /// A segment of MY voice was translated → push the Grok VOICE to the peer.
  /// Voice-only: {voiceOnly, lang, audio} (no text), so the peer just plays it.
  void _onTranslation(String orig, String trans, String lang, String audioB64) {
    _lastTranscript = orig;
    _lastTranslation = trans;
    _lastError = null;
    final room = _room;
    final route = _route;
    if (room != null &&
        audioB64.isNotEmpty &&
        audioB64.length <= _maxAudioB64) {
      final payload = jsonEncode({
        'voiceOnly': true,
        'lang': lang,
        'audio': audioB64,
      });
      unawaited(
        room.localParticipant
            ?.publishData(
              Uint8List.fromList(utf8.encode(payload)),
              reliable: true,
              topic: _captionTopic,
            )
            .catchError((_) {}),
      );
      _sent++;
      if (route != null) {
        Analytics.track(
          'translation_sent',
          langFrom: route.sourceBcp47,
          langTo: route.targetBcp47,
          props: {'phase': 'grok_rt'},
        );
      }
    }
    notifyListeners();
  }

  @override
  Future<void> detach() async {
    final s = _streamer;
    _streamer = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {}
    }
    _room = null;
    _route = null;
  }

  @override
  void dispose() {
    unawaited(detach());
    super.dispose();
  }
}
