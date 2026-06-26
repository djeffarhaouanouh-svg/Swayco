import 'dart:async';
import 'dart:convert';

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

/// Realtime Grok translation, RECEIVER-side and LOCAL playback.
///
/// Each phone captures the REMOTE participant's voice (their mic track) via the
/// streamer (web: MediaStreamTrackProcessor → PCM16 → xAI realtime STT WS),
/// translates it into MY language, and PLAYS the Grok voice locally through an
/// AudioPlayer. No data-channel forwarding, no subtitles — so it can't break on
/// the peer's build. Mirrors the old chunk pipeline that worked, but streaming.
class GrokRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  Room? _room;
  TranslationRoute? _route;
  EventsListener<RoomEvent>? _listener;

  RemoteAudioTrack? _recordTrack;
  String? _boundSid;

  GrokMicStreamer? _streamer;
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _playSub;
  bool _speaking = false;
  double _volume = 1.0;

  int _played = 0;
  String? _lastTranslation;
  String? _lastError;

  @override
  Listenable? get translationListenable => this;

  @override
  Widget? buildTranslationAudioOverlay() => null;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase {
    if (_room == null || _route == null || _route!.sourceBcp47.trim().isEmpty) {
      return TranslationFeedbackPhase.hidden;
    }
    if (_recordTrack == null) return TranslationFeedbackPhase.standby;
    return (_streamer?.isStreaming ?? false)
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
        : '${route.targetBcp47}→${route.sourceBcp47}';
    final trk = _recordTrack != null ? 'OUI' : 'NON';
    final lines = <String>[
      'Grok RT(TEST): ${_streamer?.isStreaming ?? false ? "live" : "…"} • '
          'piste: $trk • route: $routeLabel • lus: $_played',
    ];
    if (_lastTranslation != null) lines.add('TRAD: $_lastTranslation');
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
    // Receiver-side: we only need MY language to translate INTO. The remote's
    // language is just an STT hint (xAI auto-detects), so don't gate on it.
    if (route.sourceBcp47.trim().isEmpty) return;

    await _player.setReleaseMode(ReleaseMode.stop);
    _playSub = _player.onPlayerComplete.listen((_) {
      if (_speaking) {
        _speaking = false;
        notifyListeners();
      }
    });

    _listener = room.createListener()
      ..on<TrackSubscribedEvent>((e) {
        if (e.track is RemoteAudioTrack) _rebindRemoteTrack();
      })
      ..on<TrackUnsubscribedEvent>((e) {
        if (e.track is RemoteAudioTrack) _rebindRemoteTrack();
      })
      ..on<ParticipantDisconnectedEvent>((_) {
        if (_room?.remoteParticipants.isEmpty ?? true) {
          unawaited(_stopStreamer());
          _recordTrack = null;
          _boundSid = null;
          notifyListeners();
        }
      });

    _rebindRemoteTrack();
    notifyListeners();
  }

  @override
  Future<void> detach() async {
    await _stopStreamer();
    _recordTrack = null;
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

  // ─── remote track binding ────────────────────────────────────────────────
  void _rebindRemoteTrack() {
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
      if (_recordTrack != null) {
        unawaited(_stopStreamer());
        _recordTrack = null;
        _boundSid = null;
        notifyListeners();
      }
      return;
    }
    if (pickSid == _boundSid && _streamer != null) return;
    _recordTrack = pick;
    _boundSid = pickSid;
    debugPrint('[grok-rt] bound remote track sid=$pickSid');
    notifyListeners();
    unawaited(_restartStreamer(pick));
  }

  Future<void> _restartStreamer(RemoteAudioTrack track) async {
    await _stopStreamer();
    final route = _route;
    if (route == null || route.sourceBcp47.trim().isEmpty) return;
    // Receiver-side route: from = the OTHER person's language (STT hint),
    // to = MY language (what I want to hear).
    final wsUrl = grokSttWsUri(
      from: route.targetBcp47,
      to: route.sourceBcp47,
    );
    final streamer = createGrokMicStreamer();
    _streamer = streamer;
    try {
      await streamer.start(
        wsUrl: wsUrl,
        localTrack: track.mediaStreamTrack, // capture the REMOTE voice
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

  Future<void> _stopStreamer() async {
    final s = _streamer;
    _streamer = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {}
    }
  }

  /// A translated segment arrived from xAI → PLAY the Grok mp3 locally.
  void _onTranslation(String orig, String trans, String lang, String audioB64) {
    _lastTranslation = trans;
    _lastError = null;
    if (audioB64.isEmpty) {
      notifyListeners();
      return;
    }
    final route = _route;
    unawaited(_playMp3B64(audioB64));
    if (route != null) {
      Analytics.track(
        'translation_played',
        langFrom: route.targetBcp47,
        langTo: route.sourceBcp47,
        props: {'phase': 'grok_rt'},
      );
    }
    notifyListeners();
  }

  Future<void> _playMp3B64(String audioB64) async {
    try {
      final bytes = base64Decode(audioB64);
      if (bytes.isEmpty) return;
      _speaking = true;
      notifyListeners();
      await _player.setVolume(_volume);
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      _played++;
      debugPrint('[grok-rt] PLAYING Grok audio ${bytes.length}b locally');
      // _speaking cleared by onPlayerComplete.
    } catch (e) {
      _speaking = false;
      _lastError = 'play: $e';
      debugPrint('[grok-rt] LOCAL PLAY FAILED: $e');
      notifyListeners();
    }
  }
}
