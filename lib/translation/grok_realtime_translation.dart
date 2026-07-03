import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/debug_overlay.dart';
import '../services/translation_api.dart';
import 'grok_mic_streamer_base.dart';
import 'grok_mic_streamer_io.dart'
    if (dart.library.js_interop) 'grok_mic_streamer_web.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// Realtime Grok translation.
///
/// SEND (all platforms): captures MY mic, streams PCM to the backend Grok STT
/// proxy, and publishes the translated Grok voice to the peer via the LiveKit
/// data channel (voiceOnly=true). The peer plays it through
/// call_screen._onCaptionData — but ONLY on native, since on web RECV handles
/// playback (see below).
///
/// RECV (web only): captures the REMOTE participant's WebRTC audio track,
/// streams it to Grok for translation, and plays the result locally. On
/// native, the peer's SEND pipeline already sends TTS for us to play via the
/// data channel, so no RECV is needed.
///
/// On web, _onCaptionData skips voiceOnly data-channel packets (RECV handles
/// playback), which eliminates double-play and the associated speaker-echo
/// → SEND re-translation feedback loop.
class GrokRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  static const String _captionTopic = 'swayco-chat';
  static const int _maxAudioB64 = 60000;

  Room? _room;
  TranslationRoute? _route;
  EventsListener<RoomEvent>? _listener;

  GrokMicStreamer? _sendStreamer;

  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _deviceTts = FlutterTts();
  StreamSubscription<void>? _playSub;
  bool _speaking = false;
  double _volume = 1.0;

  int _sent = 0;
  String? _lastSent;
  String? _lastError;
  // Dedup: prevent publishing the same translation twice within 3 s.
  String _lastSentTrans = '';
  int _lastSentMs = 0;
  // Delta: Grok accumulates the full session context and re-sends the growing
  // translation each time. Track the last full backend text so we publish
  // only the new portion (delta) instead of the entire accumulated string.
  String _lastBackendTrans = '';

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
      'Grok RT: send=${_sendStreamer?.isStreaming ?? false} • route: $routeLabel • '
          'envois: $_sent',
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

    // RECV disabled: the remote peer's SEND pipeline delivers translations
    // via the data channel (kokoro packet → _onCaptionData → speakDeviceTts).
    // Running RECV in parallel caused double-playback and bad transcriptions
    // from degraded WebRTC audio capture.

    // SEND: my mic → peer (all platforms).
    // Pass the LiveKit local audio track so the web streamer can clone it
    // instead of opening a 2nd getUserMedia on the same device.
    final localAudioTrack =
        room.localParticipant?.audioTrackPublications.firstOrNull?.track;
    final sendStreamer = createGrokMicStreamer();
    _sendStreamer = sendStreamer;
    unawaited(
      sendStreamer
          .start(
            wsUrl: grokSttWsUri(
              from: route.sourceBcp47,
              to: route.targetBcp47,
              kokoroTts: true,
            ),
            localTrack: localAudioTrack,
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
    _lastBackendTrans = '';
    _lastSentTrans = '';
    _lastSentMs = 0;
    try {
      await _player.stop();
    } catch (_) {}
    await _listener?.dispose();
    _listener = null;
    _room = null;
    _route = null;
  }

  @override
  void dispose() {
    unawaited(_playSub?.cancel());
    unawaited(detach());
    unawaited(_player.dispose());
    unawaited(_deviceTts.stop());
    super.dispose();
  }


  // ─── SEND (my mic → peer) ────────────────────────────────────────────────
  void _onSendTranslation(String orig, String trans, String lang, String audioB64) {
    _lastSent = trans;
    _lastError = null;
    DebugOverlay.log('onSendTrans orig="${orig.substring(0, orig.length.clamp(0, 40))}" trans="${trans.substring(0, trans.length.clamp(0, 40))}" lang=$lang audio=${audioB64.length}b');

    // Delta: Grok re-sends the FULL accumulated session translation each time.
    // Only publish the portion that is new relative to the last backend response
    // so the peer doesn't hear the same phrase repeated.
    String transToSend;
    if (_lastBackendTrans.isNotEmpty && trans.startsWith(_lastBackendTrans)) {
      transToSend = trans.substring(_lastBackendTrans.length).trim();
    } else {
      transToSend = trans;
    }
    _lastBackendTrans = trans;

    if (transToSend.isEmpty) {
      DebugOverlay.log('delta empty — skip publish');
      notifyListeners();
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Dedup: same delta within 3 s → skip.
    if (transToSend == _lastSentTrans && nowMs - _lastSentMs < 3000) {
      DebugOverlay.log('dedup — same delta <3s, skip');
      notifyListeners();
      return;
    }
    _lastSentTrans = transToSend;
    _lastSentMs = nowMs;

    final room = _room;
    final route = _route;
    if (room != null && transToSend.isNotEmpty) {
      final Map<String, dynamic> payload;
      if (audioB64.isNotEmpty && audioB64.length <= _maxAudioB64) {
        payload = {
          'voiceOnly': true,
          'orig': orig,
          'trans': transToSend,
          'lang': lang,
          'audio': audioB64,
        };
      } else {
        payload = {
          'kokoro': true,
          'orig': orig,
          'trans': transToSend,
          'lang': lang,
        };
      }
      DebugOverlay.log('publishData type=${payload.containsKey('kokoro') ? 'kokoro' : 'voiceOnly'} trans="${transToSend.substring(0, transToSend.length.clamp(0, 40))}"');
      unawaited(
        room.localParticipant
            ?.publishData(
              Uint8List.fromList(utf8.encode(jsonEncode(payload))),
              reliable: true,
              topic: _captionTopic,
            )
            .catchError((Object e) => DebugOverlay.log('publishData ERROR: $e')),
      );
      _sent++;
      if (route != null) {
        Analytics.track(
          'translation_sent',
          langFrom: route.sourceBcp47,
          langTo: route.targetBcp47,
          props: {
            'phase': 'grok_rt',
            'tts': audioB64.isNotEmpty ? 'grok' : 'kokoro',
          },
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
