import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/translation_api.dart';
import 'sway_utterance_recorder_base.dart';
import 'sway_utterance_recorder_io.dart'
    if (dart.library.js_interop) 'sway_utterance_recorder_web.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// TEST translation pipeline backed by **the cloud engine**, chunk-based instead of
/// streaming.
///
/// VAD = LiveKit active-speaker events. When the remote starts talking we
/// record the utterance off their audio track; when they stop (after a short
/// silence hangover) we POST that one clip to the backend `/translation/voice`,
/// which runs the cloud engine STT → translate → TTS, and we play the returned speech.
///
/// This deliberately mirrors [RealtimeTranslationPort] so it can be swapped in
/// for `SwayLiveTranslation` at the wiring point ([main]) with no other
/// changes — the live engine path is left fully intact for an easy revert.
class SwayChunkTranslation extends ChangeNotifier implements RealtimeTranslationPort {
  @override
  ValueListenable<SpokenLine>? get localTranscript => null;

  Room? _room;
  TranslationRoute? _route;
  EventsListener<RoomEvent>? _listener;

  /// The remote mic track we record from (updated on (re)subscribe).
  RemoteAudioTrack? _recordTrack;
  String? _boundSid;

  SwayUtteranceRecorder? _recorder;
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _playSub;

  bool _remoteHot = false;
  bool _speaking = false; // translated audio currently playing
  bool _attached = false;

  // ─── utterance state machine ───────────────────────────────────────────
  bool _recording = false;
  DateTime? _utteranceStartedAt;
  Timer? _hangoverTimer;
  Timer? _maxTimer;

  /// Silence after the speaker stops before we close the utterance and send it.
  static const Duration _hangover = Duration(milliseconds: 700);
  /// Hard cap on a single utterance so one long monologue still gets sent.
  static const Duration _maxUtterance = Duration(seconds: 12);
  /// Ignore active-speaker blips shorter than this (clicks, half-words).
  static const Duration _minUtterance = Duration(milliseconds: 280);
  /// Skip clips too small to contain speech (avoids pointless STT calls).
  static const int _minBytes = 800;

  double _volume = 1.0;

  // Diagnostics for the on-screen AUDIO DEBUG panel.
  int _sent = 0;
  int _played = 0;
  String? _lastTranscript;
  String? _lastTranslation;
  String? _lastError;
  int _inFlight = 0;

  @override
  Listenable? get translationListenable => this;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase {
    if (_room == null || _route == null || !_route!.isConfigured) {
      return TranslationFeedbackPhase.hidden;
    }
    if (_recordTrack == null) return TranslationFeedbackPhase.standby;
    if (_recording || _inFlight > 0) return TranslationFeedbackPhase.working;
    return TranslationFeedbackPhase.live;
  }

  @override
  bool get translationRemoteVoiceHot => _remoteHot;

  @override
  bool get translationSpeaking => _speaking;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    try {
      await _player.setVolume(_volume);
    } catch (e) {
      debugPrint('stream translation: setVolume failed: $e');
    }
  }

  @override
  Widget? buildTranslationAudioOverlay() => null; // audioplayers handles output

  @override
  set peerGender(String value) {}

  @override
  void notePeerUtterance(String orig) {}

  @override
  String get translationDiagnostics {
    final route = _route;
    final String routeLabel;
    if (route == null) {
      routeLabel = 'NULL';
    } else if (!route.isConfigured) {
      routeLabel = 'NON-CONFIG';
    } else {
      routeLabel = '${route.targetBcp47}→${route.sourceBcp47}';
    }
    final trk = _recordTrack != null ? 'OUI' : 'NON';
    final state = _recording ? 'enregistre' : (_inFlight > 0 ? 'envoi…' : 'prêt');
    final base = 'Stream(TEST): $state • piste: $trk • route: $routeLabel • '
        'parle: ${_speaking ? "oui" : "non"} • envois: $_sent • lus: $_played';
    final lines = <String>[base];
    if (_lastTranscript != null) lines.add('STT: $_lastTranscript');
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
    _attached = true;
    if (!route.isConfigured) return;

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
      ..on<ActiveSpeakersChangedEvent>(_onActiveSpeakersChanged)
      ..on<ParticipantDisconnectedEvent>((_) {
        if (_room?.remoteParticipants.isEmpty ?? true) {
          _recordTrack = null;
          _boundSid = null;
          unawaited(_abortUtterance());
          notifyListeners();
        }
      });

    _rebindRemoteTrack();
    notifyListeners();
  }

  @override
  Future<void> detach() async {
    _attached = false;
    _hangoverTimer?.cancel();
    _hangoverTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    await _abortUtterance();
    _recordTrack = null;
    _boundSid = null;
    _remoteHot = false;
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
    if (room == null) return;
    RemoteAudioTrack? pick;
    String? pickSid;
    RemoteAudioTrack? fallback;
    String? fallbackSid;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t is! RemoteAudioTrack) continue;
        if (t.source == TrackSource.screenShareAudio) continue;
        if (t.source == TrackSource.microphone) {
          pick = t;
          pickSid = pub.sid;
          break;
        }
        fallback ??= t;
        fallbackSid ??= pub.sid;
      }
      if (pick != null) break;
    }
    pick ??= fallback;
    pickSid ??= fallbackSid;

    if (pick == null) {
      if (_recordTrack != null) {
        _recordTrack = null;
        _boundSid = null;
        notifyListeners();
      }
      return;
    }
    if (pickSid == _boundSid && _recordTrack != null) return;
    _recordTrack = pick;
    _boundSid = pickSid;
    notifyListeners();
  }

  // ─── VAD endpointing ─────────────────────────────────────────────────────
  void _onActiveSpeakersChanged(ActiveSpeakersChangedEvent e) {
    final hot = e.speakers.any((p) => p is RemoteParticipant);
    if (hot == _remoteHot) {
      if (hot) _hangoverTimer?.cancel(); // sustained speech — keep recording
      return;
    }
    _remoteHot = hot;
    if (hot) {
      _hangoverTimer?.cancel();
      _hangoverTimer = null;
      _maybeStartUtterance();
    } else if (_recording) {
      // Speaker paused — wait out the hangover before closing the utterance.
      _hangoverTimer?.cancel();
      _hangoverTimer = Timer(_hangover, () {
        if (!_remoteHot && _recording) _finalizeUtterance();
      });
    }
    notifyListeners();
  }

  void _maybeStartUtterance() {
    if (!_attached || _recording) return;
    final track = _recordTrack;
    if (track == null) return;
    final route = _route;
    if (route == null || !route.isConfigured) return;
    unawaited(_startUtterance(track));
  }

  Future<void> _startUtterance(RemoteAudioTrack track) async {
    final rec = createSwayRecorder();
    try {
      await rec.start(track.mediaStreamTrack);
    } catch (e) {
      _lastError = _short('rec.start', e);
      debugPrint('stream translation: recorder start failed: $e');
      try {
        await rec.dispose();
      } catch (_) {}
      notifyListeners();
      return;
    }
    _recorder = rec;
    _recording = true;
    _utteranceStartedAt = DateTime.now();
    _maxTimer?.cancel();
    _maxTimer = Timer(_maxUtterance, () {
      if (_recording) _finalizeUtterance();
    });
    notifyListeners();
  }

  Future<void> _finalizeUtterance() async {
    if (!_recording) return;
    final rec = _recorder;
    final startedAt = _utteranceStartedAt;
    _recorder = null;
    _recording = false;
    _hangoverTimer?.cancel();
    _hangoverTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _utteranceStartedAt = null;
    notifyListeners();

    if (rec == null) return;
    final filename = rec.filename;
    final tooShort = startedAt != null &&
        DateTime.now().difference(startedAt) < _minUtterance;
    final bytes = await rec.stopAndRead();
    if (tooShort || bytes == null || bytes.length < _minBytes) {
      return; // blip / silence / unsupported recorder — nothing to send
    }
    unawaited(_sendAndPlay(bytes, filename));
  }

  /// Drop the in-progress recording without sending (room/remote gone).
  Future<void> _abortUtterance() async {
    _recording = false;
    final rec = _recorder;
    _recorder = null;
    _hangoverTimer?.cancel();
    _hangoverTimer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _utteranceStartedAt = null;
    if (rec != null) {
      try {
        await rec.dispose();
      } catch (_) {}
    }
  }

  Future<void> _sendAndPlay(Uint8List bytes, String filename) async {
    final route = _route;
    if (route == null || !route.isConfigured) return;
    _inFlight++;
    _sent++;
    notifyListeners();
    try {
      final result = await fetchVoiceTranslation(
        audioBytes: bytes,
        to: route.sourceBcp47,
        from: route.targetBcp47,
        filename: filename,
      );
      if (result == null) {
        return; // 204 (nothing said) or recoverable error
      }
      _lastTranscript = result.transcript;
      _lastTranslation = result.translation;
      _lastError = null;
      final audio = result.audio;
      if (audio != null && audio.isNotEmpty) {
        await _playMp3(audio);
      }
    } on TranslationApiException catch (e) {
      _lastError = _short('stream', e);
      Analytics.track(
        'translation_error',
        langFrom: route.targetBcp47,
        langTo: route.sourceBcp47,
        props: {'phase': 'stream', 'message': e.toString()},
      );
    } catch (e) {
      _lastError = _short('stream', e);
    } finally {
      _inFlight--;
      notifyListeners();
    }
  }

  Future<void> _playMp3(Uint8List bytes) async {
    try {
      _speaking = true;
      notifyListeners();
      await _player.setVolume(_volume);
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      _played++;
      // _speaking is cleared by the onPlayerComplete subscription.
    } catch (e) {
      _speaking = false;
      _lastError = _short('play', e);
      debugPrint('stream translation: playback failed: $e');
      notifyListeners();
    }
  }

  static String _short(String phase, Object e) {
    var s = e.toString().replaceAll('\n', ' ');
    if (s.length > 90) s = '${s.substring(0, 90)}…';
    return '$phase: $s';
  }
}
