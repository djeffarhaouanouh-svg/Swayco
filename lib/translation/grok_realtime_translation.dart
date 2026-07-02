import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/call_audio.dart';
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
  GrokMicStreamer? _recvStreamer;
  RemoteAudioTrack? _recvTrack;
  String? _boundSid;

  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _deviceTts = FlutterTts();
  StreamSubscription<void>? _playSub;
  bool _speaking = false;
  double _volume = 1.0;

  int _sent = 0;
  int _played = 0;
  String? _lastSent;
  String? _lastRecv;
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
          'recv=${_recvStreamer?.isStreaming ?? false} • route: $routeLabel • '
          'envois: $_sent lus: $_played',
    ];
    if (_lastSent != null) lines.add('MOI→: $_lastSent');
    if (_lastRecv != null) lines.add('→MOI: $_lastRecv');
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

    // RECV (web only): captures the peer's WebRTC audio track and plays the
    // Grok translation locally. On native the peer's SEND pipeline already
    // pushes TTS via the data channel, so no RECV is needed there.
    // On web, _onCaptionData deliberately skips voiceOnly packets so only
    // RECV plays the audio — this prevents double-playback and the
    // speaker-echo → SEND re-translation feedback loop.
    if (kIsWeb) {
      _listener = room.createListener()
        ..on<TrackSubscribedEvent>((e) {
          if (e.track is RemoteAudioTrack) _rebindRemote();
        })
        ..on<TrackUnsubscribedEvent>((e) {
          if (e.track is RemoteAudioTrack) _rebindRemote();
        })
        ..on<ParticipantDisconnectedEvent>((_) {
          if (_room?.remoteParticipants.isEmpty ?? true) {
            unawaited(_stopRecv());
            _recvTrack = null;
            _boundSid = null;
            notifyListeners();
          }
        });
      _rebindRemote();
    }

    // SEND: my mic → peer (all platforms).
    final sendStreamer = createGrokMicStreamer();
    _sendStreamer = sendStreamer;
    unawaited(
      sendStreamer
          .start(
            wsUrl: grokSttWsUri(
              from: route.sourceBcp47,
              to: route.targetBcp47,
              // Skip server TTS everywhere: native uses Kokoro, web uses device TTS.
              kokoroTts: true,
            ),
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
    await _stopRecv();
    _recvTrack = null;
    _boundSid = null;
    _speaking = false;
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

  // ─── RECV (remote → local playback, web only) ────────────────────────────
  void _rebindRemote() {
    final room = _room;
    final route = _route;
    if (room == null || route == null) return;
    RemoteAudioTrack? pick;
    String? pickSid;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t is! RemoteAudioTrack) continue;
        if (t.source == TrackSource.screenShareAudio) continue;
        pick = t;
        pickSid = pub.sid;
        if (t.source == TrackSource.microphone) break;
      }
      if (pick != null) break;
    }
    if (pick == null) {
      if (_recvTrack != null) {
        unawaited(_stopRecv());
        _recvTrack = null;
        _boundSid = null;
        notifyListeners();
      }
      return;
    }
    if (pickSid == _boundSid && _recvStreamer != null) return;
    _recvTrack = pick;
    _boundSid = pickSid;
    debugPrint('[grok-rt] bound remote track sid=$pickSid');
    notifyListeners();
    unawaited(_restartRecv(pick));
  }

  Future<void> _restartRecv(RemoteAudioTrack track) async {
    await _stopRecv();
    final route = _route;
    if (route == null || !route.isConfigured) return;
    final streamer = createGrokMicStreamer();
    _recvStreamer = streamer;
    try {
      await streamer.start(
        wsUrl: grokSttWsUri(
          from: route.targetBcp47,
          to: route.sourceBcp47,
          kokoroTts: true, // no Grok TTS on web RECV — we use device TTS
        ),
        localTrack: track.mediaStreamTrack,
        captureLocalMic: false,
        onTranslation: _onRecvTranslation,
        onError: (code) {
          _lastError = 'recv:$code';
          notifyListeners();
        },
      );
    } catch (e) {
      _lastError = 'recv:$e';
    }
    notifyListeners();
  }

  void _onRecvTranslation(String orig, String trans, String lang, String audioB64) {
    _lastRecv = trans;
    _lastError = null;
    // On web with kokoro=true, audio is empty: data channel handles TTS playback.
    if (audioB64.isNotEmpty) unawaited(_playMp3B64(audioB64));
    notifyListeners();
  }

  Future<void> _playMp3B64(String audioB64) async {
    try {
      final bytes = base64Decode(audioB64);
      if (bytes.isEmpty) return;
      // Web: play through the gesture-unlocked element. This also sets
      // isTranslationPlaying so the SEND streamer pauses (half-duplex),
      // preventing the speaker-echo → SEND re-translation feedback loop.
      if (kIsWeb) {
        final ok = await playTranslatedMp3(bytes);
        debugPrint('[grok-rt] RECV web play ok=$ok ${bytes.length}b');
        if (ok) {
          _played++;
          return;
        }
      }
      _speaking = true;
      notifyListeners();
      await _player.setVolume(_volume);
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      _played++;
      debugPrint('[grok-rt] RECV played ${bytes.length}b locally');
    } catch (e) {
      _speaking = false;
      _lastError = 'play:$e';
      debugPrint('[grok-rt] RECV play FAILED: $e');
      notifyListeners();
    }
  }

  // ─── SEND (my mic → peer) ────────────────────────────────────────────────
  void _onSendTranslation(String orig, String trans, String lang, String audioB64) {
    _lastSent = trans;
    _lastError = null;
    final room = _room;
    final route = _route;
    if (room != null && trans.isNotEmpty) {
      final Map<String, dynamic> payload;
      if (audioB64.isNotEmpty && audioB64.length <= _maxAudioB64) {
        // Web path: Grok TTS audio included.
        // Also carries orig/trans for backward-compat with older native builds.
        payload = {
          'voiceOnly': true,
          'orig': orig,
          'trans': trans,
          'lang': lang,
          'audio': audioB64,
        };
      } else {
        // Native Kokoro path: no TTS audio — receiver synthesises locally.
        payload = {
          'kokoro': true,
          'orig': orig,
          'trans': trans,
          'lang': lang,
        };
      }
      unawaited(
        room.localParticipant
            ?.publishData(
              Uint8List.fromList(utf8.encode(jsonEncode(payload))),
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

  Future<void> _stopRecv() async {
    final s = _recvStreamer;
    _recvStreamer = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {}
    }
  }
}
