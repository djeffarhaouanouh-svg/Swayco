import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/call_audio.dart';
import '../services/translation_api.dart';
import 'grok_mic_streamer_base.dart';
import 'grok_mic_streamer_io.dart'
    if (dart.library.js_interop) 'grok_mic_streamer_web.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// Realtime Grok translation, HYBRID (web does everything; the peer only plays).
///
/// iOS can PLAY translated audio but cannot capture call audio, so the web side
/// runs BOTH directions:
///  - SEND: capture MY mic (getUserMedia) → translate into the peer's language →
///    push the Grok voice to the peer (voice-only) → the peer just plays it.
///  - RECV: capture the REMOTE participant's voice → translate into MY language →
///    play the Grok voice LOCALLY.
/// No subtitles either way. The peer (iOS) needs nothing but playback.
class GrokRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  static const String _captionTopic = 'swayco-chat';
  static const int _maxAudioB64 = 60000;

  Room? _room;
  TranslationRoute? _route;
  EventsListener<RoomEvent>? _listener;

  GrokMicStreamer? _sendStreamer; // my mic → peer
  GrokMicStreamer? _recvStreamer; // remote voice → local playback
  RemoteAudioTrack? _recvTrack;
  String? _boundSid;

  final AudioPlayer _player = AudioPlayer();
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
      'Grok RT(TEST): send=${_sendStreamer?.isStreaming ?? false} '
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

    // RECV FIRST — this is the translation I HEAR. It must NOT be blocked by the
    // SEND's getUserMedia (which can be slow). Bound when the remote track appears.
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

    // SEND: my mic → peer. Fire-and-forget so a slow/failed getUserMedia never
    // blocks the RECV playback above.
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
    super.dispose();
  }

  // ─── RECV (remote → local playback) ──────────────────────────────────────
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
        wsUrl: grokSttWsUri(from: route.targetBcp47, to: route.sourceBcp47),
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
    if (audioB64.isNotEmpty) unawaited(_playMp3B64(audioB64));
    notifyListeners();
  }

  Future<void> _playMp3B64(String audioB64) async {
    try {
      final bytes = base64Decode(audioB64);
      if (bytes.isEmpty) return;
      // Web: play through the gesture-unlocked element (also drives the
      // half-duplex flag so the mic streamer pauses while this plays).
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
    if (room != null && audioB64.isNotEmpty && audioB64.length <= _maxAudioB64) {
      // Include orig/trans for BACKWARD COMPAT: a native iOS app on an OLD build
      // has no `voiceOnly` branch — it reads orig/trans and speaks `trans` via
      // /translation/tts (Grok voice). New web clients see voiceOnly=true, play
      // the attached audio, and skip the subtitle.
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
