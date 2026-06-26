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

/// Realtime translation backed by **Grok (xAI)**, **sender-side**: this phone
/// streams its OWN microphone to the backend STT WebSocket, gets back the
/// translation (into the peer's language) + speech, and pushes the result to the
/// peer over the LiveKit data channel. The peer displays the caption and speaks
/// it. Both phones run this port, so each hears the other's translation.
///
/// Contrast with [RealtimeTranslationPort]'s old chunk pipeline, which recorded
/// the REMOTE track (receiver-side). Capturing the local mic is what makes this
/// native-friendly (no PCM tap on a remote WebRTC stream) — though the streaming
/// capture itself is **web-first** today; native is a stub (see grok_mic_streamer_io).
class GrokRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  /// Must match call_screen's `_captionTopic` so the peer's `_onCaptionData`
  /// picks up what we publish (same shape as the typed-chat captions).
  static const String _captionTopic = 'swayco-chat';

  Room? _room;
  TranslationRoute? _route;
  GrokMicStreamer? _streamer;

  // Diagnostics for the on-screen AUDIO DEBUG panel.
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

  // The peer plays our translation; this side never plays translated audio.
  @override
  bool get translationSpeaking => false;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {}

  @override
  String get translationDiagnostics {
    final route = _route;
    final String routeLabel;
    if (route == null) {
      routeLabel = 'NULL';
    } else if (!route.isConfigured) {
      routeLabel = 'NON-CONFIG';
    } else {
      // sender-side: I speak source → translate to target (peer's language)
      routeLabel = '${route.sourceBcp47}→${route.targetBcp47}';
    }
    final s = _streamer;
    final state = s == null
        ? 'inactif'
        : (s.isStreaming ? 'micro→STT' : 'connexion…');
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
    if (!route.isConfigured) return;

    // Sender-side route: from = my spoken language, to = the peer's language.
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

  /// The LiveKit local mic track, if published (used by the native streamer to
  /// fork an already-AEC'd stream; the web streamer ignores it).
  MediaStreamTrack? _localMicTrack(Room room) {
    for (final pub in room.localParticipant?.audioTrackPublications ?? const []) {
      final t = pub.track;
      if (t is LocalAudioTrack) return t.mediaStreamTrack;
    }
    return null;
  }

  /// One utterance finalised + translated → push to the peer over the data
  /// channel (same {orig, trans, lang} shape the typed chat uses, so the peer's
  /// `_onCaptionData` displays it and speaks the translation).
  void _onTranslation(String orig, String trans, String lang) {
    _lastTranscript = orig;
    _lastTranslation = trans;
    _lastError = null;
    final room = _room;
    final route = _route;
    if (room != null && trans.isNotEmpty) {
      final payload = jsonEncode({'orig': orig, 'trans': trans, 'lang': lang});
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
