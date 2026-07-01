import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/translation_api.dart';
import 'grok_mic_streamer_base.dart';
import 'grok_mic_streamer_io.dart'
    if (dart.library.js_interop) 'grok_mic_streamer_web.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// Realtime Grok translation — SEND-only (each device sends its own TTS).
///
/// Each participant captures its own mic, streams PCM to the backend Grok STT
/// proxy, receives the translated audio, and publishes it to the peer via the
/// LiveKit data channel (topic: swayco-chat, voiceOnly=true). The peer plays
/// it through call_screen._onCaptionData.
///
/// RECV was removed: running a parallel RECV capture on web caused
/// double-playback and a speaker-echo feedback loop where the sender heard
/// its own text reflected back as TTS.
class GrokRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  static const String _captionTopic = 'swayco-chat';
  static const int _maxAudioB64 = 60000;

  Room? _room;
  TranslationRoute? _route;

  GrokMicStreamer? _sendStreamer;

  // _player kept for setTranslatedAudioVolume interface compliance; volume
  // controls the data-channel TTS playback in call_screen instead.
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _playSub;
  bool _speaking = false;
  double _volume = 1.0;

  int _sent = 0;
  String? _lastSent;
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
    return (_sendStreamer?.isStreaming ?? false)
        ? TranslationFeedbackPhase.live
        : TranslationFeedbackPhase.working;
  }

  @override
  bool get translationRemoteVoiceHot => false;

  @override
  bool get translationSpeaking => _speaking;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    try {
      await _player.setVolume(_volume);
    } catch (_) {}
  }

  @override
  String get translationDiagnostics {
    final route = _route;
    final routeLabel = route == null
        ? 'NULL'
        : (!route.isConfigured
            ? 'NON-CONFIG'
            : '${route.sourceBcp47}↔${route.targetBcp47}');
    final lines = <String>[
      'Grok RT: send=${_sendStreamer?.isStreaming ?? false} '
          '• route: $routeLabel • envois: $_sent',
    ];
    if (_lastSent != null) lines.add('MOI→: $_lastSent');
    if (_lastError != null) lines.add('ERR: $_lastError');
    return lines.join('\n');
  }

  // ─── attach / detach ────────────────────────────────────────────────────
  @override
  Future<void> attachToRoom(Room room, {required TranslationRoute route}) async {
    await detach();
    _room = room;
    _route = route;
    debugPrint('[grok-rt] attach src=${route.sourceBcp47} tgt=${route.targetBcp47}');
    if (!route.isConfigured) return;

    await _player.setReleaseMode(ReleaseMode.stop);
    _playSub = _player.onPlayerComplete.listen((_) {
      if (_speaking) {
        _speaking = false;
        notifyListeners();
      }
    });

    // RECV is intentionally disabled: every client (iOS + web) already runs a
    // SEND pipeline that translates its own mic and pushes TTS to the peer via
    // the data channel. Running RECV in parallel caused double-playback on web
    // AND a speaker-echo → SEND re-translation feedback loop.

    // SEND: my mic → peer.
    final sendStreamer = createGrokMicStreamer();
    _sendStreamer = sendStreamer;
    unawaited(
      sendStreamer
          .start(
            wsUrl: grokSttWsUri(from: route.sourceBcp47, to: route.targetBcp47),
            captureLocalMic: true,
            onTranslation: _onSendTranslation,
            onError: (code) {
              _lastError = 'send:$code';
              notifyListeners();
            },
          )
          .catchError((Object e) {
            _lastError = 'send:$e';
            notifyListeners();
          }),
    );
    notifyListeners();
  }

  @override
  Future<void> detach() async {
    await _stopSend();
    _speaking = false;
    try {
      await _player.stop();
    } catch (_) {}
    _room = null;
    _route = null;
  }

  @override
  void dispose() {
    unawaited(_playSub?.cancel());
    unawaited(detach());
    unawaited(_player.dispose());
    super.dispose();
  }

  // ─── SEND (my mic → peer) ────────────────────────────────────────────────
  void _onSendTranslation(String orig, String trans, String lang, String audioB64) {
    _lastSent = trans;
    _lastError = null;
    final room = _room;
    final route = _route;
    if (room != null && audioB64.isNotEmpty && audioB64.length <= _maxAudioB64) {
      // Include orig/trans for BACKWARD COMPAT: an iOS app on an older build
      // without voiceOnly support reads orig/trans and re-synthesizes via TTS.
      final payload = jsonEncode({
        'voiceOnly': true,
        'orig': orig,
        'trans': trans,
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

  Future<void> _stopSend() async {
    final s = _sendStreamer;
    _sendStreamer = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {}
    }
  }
}
