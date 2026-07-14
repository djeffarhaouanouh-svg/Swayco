import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/analytics.dart';
import '../services/translation_api.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// Listens to the **remote** LiveKit microphone, runs the live translation engine
/// (WebRTC), and plays translated audio locally in your language ([TranslationRoute.sourceBcp47]).
///
/// Only [TrackSource.microphone] (or unknown-labeled mic) is sent to the live engine — never
/// [TrackSource.screenShareAudio], so tab/system capture is not translated (avoids re-feeding
/// TTS or call audio published as screen-audio).
///
/// Translated audio plays on a **second** WebRTC connection; OS echo cancellation may not
/// fully remove that playback from **your** mic. Prefer headphones / lower speaker volume
/// so the remote party does not send leaked translation back into this pipeline.
///
/// Renews the live engine side before the ephemeral credential expires and retries on failure.
class SwayLiveTranslation extends ChangeNotifier implements RealtimeTranslationPort {
  @override
  ValueListenable<SpokenLine>? get localTranscript => null;

  Room? _room;
  TranslationRoute? _route;
  EventsListener<RoomEvent>? _listener;

  RemoteAudioTrack? _cachedRemote;
  String? _boundPublicationSid;

  RTCPeerConnection? _pc;
  RTCVideoRenderer? _renderer;
  MediaStream? _localStream;
  /// The actual audio MediaStreamTrack arriving from the live engine. Stored so we
  /// can change its volume via Helper.setVolume() — RTCVideoRenderer's
  /// setVolume is unreliable on Safari/iOS when the renderer view is
  /// hidden/off-screen, but Helper.setVolume targets the track directly.
  MediaStreamTrack? _translatedAudioTrack;
  Timer? _refreshTimer;
  /// Recovers if the one-shot refresh timer was never rescheduled (early returns, races).
  Timer? _watchdogTimer;
  bool _busy = false;
  DateTime? _lastConnectionDropSchedule;
  bool _remoteVoiceHot = false;
  /// True while the live engine is actually streaming translated audio out over the
  /// WebRTC connection — bounded by the `output_audio_buffer.started` /
  /// `.stopped` events on the `oai-events` data channel.
  bool _translationSpeaking = false;
  bool _wasPcConnected = false;

  /// Diagnostics for the on-screen AUDIO DEBUG panel (the user builds on a
  /// remote Mac and cannot read device logs). [_openAttempts] counts how many
  /// times we tried to open the live pipeline; [_lastOpenError] is the most
  /// recent failure reason (null once a connection succeeds). These reveal,
  /// on the phone itself, whether the pipeline never tries (route problem) or
  /// tries and throws (and exactly why).
  int _openAttempts = 0;
  String? _lastOpenError;

  /// Wall-clock moment the current pipeline open began (set at the top
  /// of [_openPipelineCore]). The gap to the first "pc connected" is
  /// reported as `translation_connected` setup latency for the
  /// dashboard's average-latency figure.
  DateTime? _pipelineOpenStartedAt;

  /// Playback volume for the translated-audio renderer in [0, 1]. Stored
  /// here so the value survives renderer rebuilds (refresh / reconnect).
  double _translatedVolume = 1.0;

  // ─── VAD pause/resume ───────────────────────────────────────────────
  /// Polls every [_vadPollInterval] to decide whether the call has been
  /// silent long enough to tear down the live pipeline (and stop the
  /// billing meter). Re-armed by [_onActiveSpeakersChanged] when the
  /// remote starts talking again.
  Timer? _vadIdleTimer;
  DateTime _lastSpeakerActiveAt = DateTime.now();
  bool _pausedForSilence = false;
  static const Duration _silenceThreshold = Duration(seconds: 20);
  static const Duration _vadPollInterval = Duration(seconds: 2);

  @override
  Listenable? get translationListenable => this;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase {
    if (_room == null || _route == null || !_route!.isConfigured) {
      return TranslationFeedbackPhase.hidden;
    }
    final pc = _pc;
    if (pc != null) {
      final cs = pc.connectionState ?? RTCPeerConnectionState.RTCPeerConnectionStateNew;
      if (cs == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        return TranslationFeedbackPhase.live;
      }
      return TranslationFeedbackPhase.working;
    }
    if (_busy) {
      return TranslationFeedbackPhase.working;
    }
    return TranslationFeedbackPhase.standby;
  }

  @override
  bool get translationRemoteVoiceHot => _remoteVoiceHot;

  @override
  bool get translationSpeaking => _translationSpeaking;

  @override
  String get translationDiagnostics {
    final pc = _pc;
    final cs = pc?.connectionState;
    String pcLabel;
    switch (cs) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        pcLabel = 'connectée';
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        pcLabel = 'connexion…';
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        pcLabel = 'ECHEC';
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        pcLabel = 'coupee';
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        pcLabel = 'fermee';
        break;
      case null:
        pcLabel = _busy ? 'ouverture…' : 'absente';
        break;
      default:
        pcLabel = cs.toString().split('.').last;
    }
    final room = _room;
    var origTracks = 0;
    if (room != null) {
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.audioTrackPublications) {
          if (pub.track is RemoteAudioTrack) origTracks++;
        }
      }
    }
    final trk = _translatedAudioTrack != null ? 'OUI' : 'NON';
    final speaking = _translationSpeaking ? 'oui' : 'non';
    final extra = _pausedForSilence ? ' • pause(silence)' : '';
    final route = _route;
    final String routeLabel;
    if (route == null) {
      routeLabel = 'NULL';
    } else if (!route.isConfigured) {
      routeLabel = 'NON-CONFIG';
    } else {
      routeLabel = '${route.targetBcp47}/${route.sourceBcp47}';
    }
    final err = _lastOpenError;
    final base = 'the live engine: $pcLabel • trad recue: $trk • parle: $speaking • '
        'orig: $origTracks piste(s) • route: $routeLabel • essais: $_openAttempts$extra';
    return err == null ? base : '$base\nERR: $err';
  }

  /// Compact, single-line error label for the on-screen panel (full message
  /// still goes to Analytics). Trimmed so it fits the debug overlay.
  static String _shortError(String phase, Object e) {
    var s = e.toString().replaceAll('\n', ' ');
    if (s.length > 90) s = '${s.substring(0, 90)}…';
    return '$phase: $s';
  }

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _translatedVolume = clamped;
    // Drive both paths in parallel: renderer.setVolume helps on desktop /
    // Android, Helper.setVolume on the audio track itself is what actually
    // works on iOS Safari (where the hidden RTCVideoView often isn't
    // mounted and its setVolume is a no-op).
    final r = _renderer;
    if (r != null) {
      try {
        await r.setVolume(clamped);
      } catch (e) {
        debugPrint('live translation: renderer.setVolume failed: $e');
      }
    }
    final t = _translatedAudioTrack;
    if (t != null) {
      try {
        await Helper.setVolume(clamped, t);
      } catch (e) {
        debugPrint('live translation: Helper.setVolume failed: $e');
      }
    }
  }

  @override
  Widget? buildTranslationAudioOverlay() {
    final r = _renderer;
    if (r == null) return null;
    // KEEP THIS IN THE VIEWPORT (1x1 at 0,0), not off-screen. The hidden
    // RTCVideoView is what plays the live engine's translated audio; iOS (WebKit on web,
    // and the native platform view) CULLS a fully off-screen view, so its
    // audio never plays — that's the asymmetric "one side hears the
    // translation, the other only the original" bug. Re-applies dc942e7, which
    // was reverted by d882d09 by mistake. Invisible to the eye, but mounted.
    return Positioned(
      left: 0,
      bottom: 0,
      width: 1,
      height: 1,
      child: Opacity(
        opacity: 0.001,
        child: RTCVideoView(
          r,
          mirror: false,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ),
    );
  }

  void _cancelScheduledRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _scheduleNextRefreshRaw(Duration delay) {
    _cancelScheduledRefresh();
    if (_room == null || _route == null || !_route!.isConfigured) return;
    var d = delay;
    if (d < const Duration(seconds: 4)) {
      d = const Duration(seconds: 4);
    }
    _refreshTimer = Timer(d, () => unawaited(_refreshLoop()));
  }

  void _scheduleNextRefreshFromSession(Map<String, dynamic> session) {
    final at = pickSessionExpiresAt(session);
    final now = DateTime.now();
    Duration delay;
    if (at != null) {
      // Renew well before server-side expiry (short-lived client secrets).
      delay = at.difference(now) - const Duration(seconds: 25);
      if (delay < const Duration(seconds: 15)) {
        delay = const Duration(seconds: 15);
      }
    } else {
      delay = const Duration(seconds: 35);
    }
    debugPrint(
      '[xlate] schedule next refresh in ${delay.inSeconds}s '
      '(session expires_at=${at?.toIso8601String() ?? "?"} '
      'now=${now.toIso8601String()})',
    );
    _scheduleNextRefreshRaw(delay);
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 22), (_) => _watchdogTick());
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _watchdogTick() {
    if (_room == null || _route == null || !_route!.isConfigured) return;
    if (_boundPublicationSid == null && _cachedRemote == null) return;
    if (_busy) return;
    // VAD has parked the pipeline on purpose — don't fight it.
    if (_pausedForSilence) return;

    // Lost the one-shot renewal timer (e.g. silent early-return in open pipeline).
    if (_refreshTimer == null) {
      debugPrint('live translation: watchdog — no refresh timer, re-arming');
      _scheduleNextRefreshRaw(const Duration(seconds: 2));
      return;
    }

    final pc = _pc;
    if (pc != null) {
      final cs = pc.connectionState ?? RTCPeerConnectionState.RTCPeerConnectionStateNew;
      if (cs == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          cs == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          cs == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        debugPrint('live translation: watchdog — pc state $cs, forcing refresh');
        _scheduleNextRefreshRaw(const Duration(seconds: 2));
      }
    }
  }

  RemoteAudioTrack? _resolveRemoteAudio() {
    final sid = _boundPublicationSid;
    final room = _room;
    if (sid == null || room == null) return null;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        if (pub.sid == sid) {
          final t = pub.track;
          if (t is RemoteAudioTrack && _eligibleRemoteAudioForTranslation(t)) return t;
        }
      }
    }
    return null;
  }

  /// Never use screen-share / system-capture audio for speech translation.
  static bool _eligibleRemoteAudioForTranslation(RemoteAudioTrack t) =>
      t.source != TrackSource.screenShareAudio;

  /// Prefer the remote **microphone** so we do not translate screen/tab audio (which can
  /// include our own translated output played on speakers elsewhere in the graph).
  static ({RemoteAudioTrack track, String sid})? _pickTranslationRemoteTrack(Room room) {
    RemoteAudioTrack? fallback;
    String? fallbackSid;

    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t is! RemoteAudioTrack) continue;
        if (!_eligibleRemoteAudioForTranslation(t)) continue;
        if (t.source == TrackSource.microphone) {
          return (track: t, sid: pub.sid);
        }
        if (fallback == null) {
          fallback = t;
          fallbackSid = pub.sid;
        }
      }
    }

    if (fallback != null && fallbackSid != null) {
      return (track: fallback, sid: fallbackSid);
    }
    return null;
  }

  void _maybeUpgradeTranslationBinding() {
    final room = _room;
    final route = _route;
    if (room == null || route == null || !route.isConfigured) return;

    // Hard gate: never spin up the live session while we're alone in
    // the room. The ephemeral key minted by `fetchTranslationSession`
    // costs even before the first audio frame, so waiting until the
    // remote actually shows up saves us a full session per dial-tone
    // period (caller waiting for callee to pick up).
    if (room.remoteParticipants.isEmpty) {
      if (_boundPublicationSid != null || _pc != null) {
        unawaited(_onRemoteTrackEnded());
      }
      return;
    }

    final pick = _pickTranslationRemoteTrack(room);
    if (pick == null) {
      if (_boundPublicationSid != null || _pc != null) {
        unawaited(_onRemoteTrackEnded());
      }
      return;
    }

    if (_busy) return;
    if (_pc != null && _boundPublicationSid == pick.sid) return;
    debugPrint(
      '[xlate] remote present (${room.remoteParticipants.length}) → '
      'activating live session for sid=${pick.sid}',
    );
    unawaited(_bindRemoteAudio(pick.track, pick.sid));
  }

  void _onPcConnectionState(RTCPeerConnectionState state) {
    debugPrint('[xlate] pc state → $state');
    final nowConnected = state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
    if (nowConnected) _lastOpenError = null;
    if (nowConnected && !_wasPcConnected) {
      if (!kIsWeb) HapticFeedback.lightImpact();
      // Translation pipeline is live — report setup latency.
      final startedAt = _pipelineOpenStartedAt;
      if (startedAt != null) {
        final route = _route;
        Analytics.track(
          'translation_connected',
          langFrom: route?.targetBcp47,
          langTo: route?.sourceBcp47,
          latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
        );
      }
    }
    _wasPcConnected = nowConnected;
    notifyListeners();

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      if (_room == null) return;
      final now = DateTime.now();
      if (_lastConnectionDropSchedule != null &&
          now.difference(_lastConnectionDropSchedule!) < const Duration(seconds: 3)) {
        return;
      }
      _lastConnectionDropSchedule = now;
      debugPrint('[xlate] pc drop → schedule refresh in 2s');
      _scheduleNextRefreshRaw(const Duration(seconds: 2));
    }
  }

  void _onActiveSpeakersChanged(ActiveSpeakersChangedEvent e) {
    final hot = e.speakers.any((p) => p is RemoteParticipant);
    if (hot) {
      _lastSpeakerActiveAt = DateTime.now();
      // Resume the live pipeline immediately if VAD had paused it on
      // silence — translation needs to be ready before the speaker has
      // finished their first word.
      if (_pausedForSilence) {
        debugPrint('[xlate] VAD resume — speaker active');
        _pausedForSilence = false;
        _maybeUpgradeTranslationBinding();
      }
    }
    if (hot != _remoteVoiceHot) {
      _remoteVoiceHot = hot;
      notifyListeners();
    }
  }

  /// Parse an `oai-events` data-channel message and track whether the live engine
  /// is currently emitting translated audio. Over the WebRTC transport the
  /// model signals playback boundaries with `output_audio_buffer.started`
  /// / `.stopped` / `.cleared` — exactly the window during which the
  /// original remote audio should be ducked so the translation stands out.
  void _handleOaiEvent(String raw) {
    String? type;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) type = decoded['type'] as String?;
    } catch (_) {
      return; // not JSON — ignore
    }
    bool? speaking;
    if (type == 'output_audio_buffer.started') {
      speaking = true;
    } else if (type == 'output_audio_buffer.stopped' ||
        type == 'output_audio_buffer.cleared') {
      speaking = false;
    }
    if (speaking == null || speaking == _translationSpeaking) return;
    _translationSpeaking = speaking;
    notifyListeners();
  }

  void _startVadIdleWatcher() {
    _vadIdleTimer?.cancel();
    _lastSpeakerActiveAt = DateTime.now();
    _pausedForSilence = false;
    _vadIdleTimer = Timer.periodic(_vadPollInterval, (_) => _vadTick());
  }

  void _stopVadIdleWatcher() {
    _vadIdleTimer?.cancel();
    _vadIdleTimer = null;
    _pausedForSilence = false;
  }

  void _vadTick() {
    if (_pausedForSilence) return;
    if (_pc == null) return; // already torn down
    if (_busy) return;
    final silentFor = DateTime.now().difference(_lastSpeakerActiveAt);
    if (silentFor < _silenceThreshold) return;
    debugPrint(
      '[xlate] VAD pause — silent for ${silentFor.inSeconds}s, tearing down the live engine to stop billing',
    );
    _pausedForSilence = true;
    _cancelScheduledRefresh();
    unawaited(_stopMedia());
    notifyListeners();
  }

  Future<void> _stopMedia() async {
    final pc = _pc;
    _pc = null;
    _wasPcConnected = false;
    // No pipeline → no translated audio playing; un-duck the original.
    _translationSpeaking = false;
    if (pc != null) {
      try {
        pc.onConnectionState = null;
        await pc.close();
      } catch (_) {}
    }

    final ls = _localStream;
    _localStream = null;
    if (ls != null) {
      try {
        await ls.dispose();
      } catch (_) {}
    }

    // NOTE: we don't track / stop the cloned remote track on its own.
    // On Web (notably Safari/WebKit) calling MediaStreamTrack.stop() on
    // a clone propagates up to the source track in some implementations,
    // which kills the remote audio LiveKit is also using and can knock
    // the local mic out of its publication. Disposing the local stream
    // and closing the PC above is enough to release the clone.

    final r = _renderer;
    _renderer = null;
    if (r != null) {
      try {
        r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Tear down a CAPTURED (old) pipeline during a make-before-break rotation,
  /// without touching the live fields. Same safe order as [_stopMedia]: close
  /// the PC + dispose the stream/renderer, and NEVER stop the cloned remote
  /// track (stopping a clone can kill the source the remote is still using).
  Future<void> _disposePipeline(
    RTCPeerConnection? pc,
    RTCVideoRenderer? renderer,
    MediaStream? stream,
  ) async {
    if (pc != null) {
      try {
        pc.onConnectionState = null;
        await pc.close();
      } catch (_) {}
    }
    if (stream != null) {
      try {
        await stream.dispose();
      } catch (_) {}
    }
    if (renderer != null) {
      try {
        renderer.srcObject = null;
        await renderer.dispose();
      } catch (_) {}
    }
  }

  /// Opens WebRTC to the live engine; caller must set [_busy] if needed.
  Future<void> _openPipelineCore(
    RemoteAudioTrack remote,
    String publicationSid,
    Room roomRef,
  ) async {
    final route = _route;
    if (route == null || !route.isConfigured) return;
    _pipelineOpenStartedAt = DateTime.now();
    // Belt-and-braces against any code path that might reach this point
    // while the room is empty (race between detach and a stale refresh
    // timer firing). Without a remote there's nothing to translate, and
    // we don't want to burn an live session for nothing.
    if (roomRef.remoteParticipants.isEmpty) {
      debugPrint('[xlate] refusing to open pipeline — room has no remote');
      return;
    }

    // Pass `targetBcp47` (the remote speaker's language) as input language —
    // the backend forwards it as `audio.input.language` only if the env gate
    // OPENAI_TRANSLATION_PASS_INPUT_LANGUAGE=1 is on. Sending it is harmless
    // when the gate is off.
    final session = await fetchTranslationSession(
      outputLanguage: route.sourceBcp47,
      inputLanguage: route.targetBcp47,
    );
    if (!identical(_room, roomRef)) {
      throw StateError('room_changed_after_session');
    }

    final secret = pickClientSecret(session);
    if (secret == null || secret.isEmpty) {
      debugPrint('live translation: no client_secret in session response');
      throw StateError('missing client_secret');
    }

    RTCPeerConnection? pc;
    RTCVideoRenderer? renderer;
    MediaStream? ms;

    try {
      pc = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      });

      pc.onConnectionState = (RTCPeerConnectionState s) {
        if (!identical(pc, _pc)) return;
        _onPcConnectionState(s);
      };

      final dc = await pc.createDataChannel(
        'oai-events',
        RTCDataChannelInit(),
      );
      dc.onMessage = (RTCDataChannelMessage m) {
        if (m.isBinary) return;
        final t = m.text;
        if (t.length < 400) {
          debugPrint('the live engine translation dc: $t');
        }
        _handleOaiEvent(t);
      };

      // MediaStreamTrack.clone() is implemented on web but throws
      // UnimplementedError on native flutter_webrtc — this is the exact reason
      // the translation pipeline NEVER started on the iOS build: it failed here
      // on every attempt, retried every 6s, and the panel stayed "absente".
      // On native, feed the ORIGINAL remote track straight into the live engine PC.
      // Teardown (_stopMedia) only disposes this local stream + closes the PC
      // and never calls track.stop(), so the LiveKit source that the original
      // remote audio also uses is left untouched (no risk of cutting the real
      // voice). Web keeps cloning, where stopping a clone could propagate to
      // the source.
      final MediaStreamTrack srcTrack =
          kIsWeb ? await remote.mediaStreamTrack.clone() : remote.mediaStreamTrack;
      ms = await createLocalMediaStream('sway_live_src');
      await ms.addTrack(srcTrack);
      await pc.addTrack(srcTrack, ms);

      renderer = RTCVideoRenderer();
      await renderer.initialize();
      final playbackRenderer = renderer;

      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isEmpty) return;
        playbackRenderer.srcObject = event.streams[0];
        // Re-apply the user's preferred volume on every new media stream
        // (refresh / reconnect rebuilds the renderer source).
        unawaited(playbackRenderer.setVolume(_translatedVolume));
        // Capture the audio track so we can drive its volume via
        // Helper.setVolume(), which actually takes effect on iOS Safari
        // (the renderer-based path is silently ignored when the hidden
        // RTCVideoView isn't mounted in the viewport).
        final audioTracks = event.streams[0].getAudioTracks();
        if (audioTracks.isNotEmpty) {
          _translatedAudioTrack = audioTracks.first;
          unawaited(
            Helper.setVolume(_translatedVolume, _translatedAudioTrack!)
                .catchError((e) =>
                    debugPrint('live translation: Helper.setVolume failed: $e')),
          );
        }
        notifyListeners();
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp == null || sdp.isEmpty) {
        debugPrint('live translation: empty local SDP');
        throw StateError('empty local SDP');
      }

      if (!identical(_room, roomRef)) {
        throw StateError('room_changed_before_sdp');
      }

      final answerSdp = await postTranslationCallsSdp(clientSecret: secret, sdpOffer: sdp);
      if (!identical(_room, roomRef)) {
        throw StateError('room_changed_after_sdp');
      }

      await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));

      _pc = pc;
      _renderer = renderer;
      _localStream = ms;
      _boundPublicationSid = publicationSid;
      pc = null;
      renderer = null;
      ms = null;

      notifyListeners();

      // Keep LiveKit remote audio audible (original). Translated audio plays from the
      // the live engine WebRTC renderer when it arrives — user hears both.
      _scheduleNextRefreshFromSession(session);
    } finally {
      if (renderer != null) {
        try {
          renderer.srcObject = null;
          await renderer.dispose();
        } catch (_) {}
      }
      // NEVER call `.stop()` on the cloned remote track here. The clone
      // shares its source with the RemoteAudioTrack LiveKit is still
      // playing; on several WebRTC implementations stopping a clone
      // propagates up and ends the *source*, which kills the remote
      // party's audio entirely — you stop hearing them at all, not just
      // the translation. Especially likely on a flaky pipeline open
      // (weak peer device / bad network) where this finally runs often.
      // Disposing the MediaStream that holds the clone and closing the
      // PC releases it without touching the source — same reasoning as
      // documented in `_stopMedia`.
      if (ms != null) {
        try {
          await ms.dispose();
        } catch (_) {}
      }
      if (pc != null) {
        try {
          pc.onConnectionState = null;
          await pc.close();
        } catch (_) {}
      }
    }

    // If open failed without throwing (should not happen), never stay without a timer.
    if (_room != null &&
        identical(_room, roomRef) &&
        _route != null &&
        _route!.isConfigured &&
        _pc == null &&
        _refreshTimer == null &&
        !_busy) {
      debugPrint('live translation: pipeline ended without PC and without timer — retry');
      _scheduleNextRefreshRaw(const Duration(seconds: 4));
    }
  }

  Future<void> _refreshLoop() async {
    debugPrint('[xlate] refresh fire — room=${_room != null} '
        'route=${_route?.isConfigured ?? false} busy=$_busy');
    _refreshTimer = null;
    if (_room == null || _route == null || !_route!.isConfigured) {
      debugPrint('[xlate] refresh ABORT — room/route gone');
      return;
    }
    if (_busy) {
      debugPrint('[xlate] refresh defer — busy, retry 3s');
      _scheduleNextRefreshRaw(const Duration(seconds: 3));
      return;
    }

    final remote = _resolveRemoteAudio() ?? _cachedRemote;
    final sid = _boundPublicationSid;
    if (remote == null || sid == null) {
      debugPrint('[xlate] refresh defer — no remote ($remote) or sid ($sid), retry 4s');
      _scheduleNextRefreshRaw(const Duration(seconds: 4));
      return;
    }

    final roomRef = _room;
    if (roomRef == null) return;

    _busy = true;
    try {
      debugPrint('[xlate] refresh START — make-before-break rotation');
      // Capture the CURRENT (old) pipeline but DON'T tear it down yet: it keeps
      // playing translated audio while the replacement comes up, so rotating
      // the live session at its ~10-min expiry leaves NO silent gap.
      final oldPc = _pc;
      final oldRenderer = _renderer;
      final oldStream = _localStream;
      // Open + connect the NEW pipeline. On success it swaps itself into
      // _pc/_renderer/_localStream (the old refs now live only in the locals
      // above). If it THROWS, the fields are untouched — the OLD pipeline is
      // still live — and the catch retries: still no break.
      await _openPipelineCore(remote, sid, roomRef);
      if (!identical(_room, roomRef)) {
        await _disposePipeline(oldPc, oldRenderer, oldStream);
        return;
      }
      // New pipeline is now the live _pc. Give its translated audio ~1.5s to
      // start flowing, then retire the OLD one — a brief overlap of the same
      // translated speech, never a gap.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _disposePipeline(oldPc, oldRenderer, oldStream);
      debugPrint('[xlate] refresh OK — rotated with no gap');
    } catch (e, st) {
      debugPrint('[xlate] refresh FAILED: $e\n$st');
      _lastOpenError = _shortError('refresh', e);
      Analytics.track(
        'translation_error',
        langFrom: _route?.targetBcp47,
        langTo: _route?.sourceBcp47,
        props: {'phase': 'refresh', 'message': e.toString()},
      );
      // The replacement failed to come up; the OLD pipeline is still live in
      // the fields — leave it running and just retry the rotation soon.
      _scheduleNextRefreshRaw(const Duration(seconds: 6));
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> attachToRoom(Room room, {required TranslationRoute route}) async {
    await detach();
    _room = room;
    _route = route;
    if (!route.isConfigured) return;

    _listener = room.createListener()
      ..on<TrackSubscribedEvent>(_onTrackSubscribed)
      ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
      ..on<ActiveSpeakersChangedEvent>(_onActiveSpeakersChanged)
      // If the remote disconnects from the room entirely, kill the
      // live pipeline immediately — there's nobody left to translate
      // and we don't want the billing meter to keep ticking until the
      // user manually leaves.
      ..on<ParticipantDisconnectedEvent>((_) {
        if (_room == null) return;
        final remotes = _room!.remoteParticipants;
        if (remotes.isEmpty) {
          debugPrint('[xlate] last remote left — detaching the live engine');
          unawaited(detach());
        }
      });

    notifyListeners();

    _startWatchdog();
    _startVadIdleWatcher();

    _maybeUpgradeTranslationBinding();
  }

  void _onTrackSubscribed(TrackSubscribedEvent e) {
    final t = e.track;
    if (t is RemoteAudioTrack && _eligibleRemoteAudioForTranslation(t)) {
      _maybeUpgradeTranslationBinding();
    }
  }

  void _onTrackUnsubscribed(TrackUnsubscribedEvent e) {
    final t = e.track;
    if (t is RemoteAudioTrack) {
      _maybeUpgradeTranslationBinding();
    }
  }

  Future<void> _onRemoteTrackEnded() async {
    _cancelScheduledRefresh();
    _stopWatchdog();
    _cachedRemote = null;
    _boundPublicationSid = null;
    _remoteVoiceHot = false;
    await _stopMedia();
  }

  Future<void> _bindRemoteAudio(RemoteAudioTrack remote, String publicationSid) async {
    final roomRef = _room;
    final route = _route;
    if (roomRef == null || route == null || !route.isConfigured) return;
    if (!_eligibleRemoteAudioForTranslation(remote)) return;
    if (_busy) return;
    if (_pc != null && _boundPublicationSid == publicationSid) return;

    _cachedRemote = remote;
    _boundPublicationSid = publicationSid;

    _busy = true;
    try {
      if (_pc != null) {
        await _stopMedia();
      }
      if (!identical(_room, roomRef)) return;
      _openAttempts++;
      await _openPipelineCore(remote, publicationSid, roomRef);
      _lastOpenError = null;
    } catch (e, st) {
      debugPrint('live translation failed: $e\n$st');
      _lastOpenError = _shortError('bind', e);
      Analytics.track(
        'translation_error',
        langFrom: _route?.targetBcp47,
        langTo: _route?.sourceBcp47,
        props: {'phase': 'bind', 'message': e.toString()},
      );
      await _stopMedia();
      _scheduleNextRefreshRaw(const Duration(seconds: 6));
    } finally {
      _busy = false;
    }
  }

  Future<void> _fullDetachMediaAndTimer() async {
    _cancelScheduledRefresh();
    _stopWatchdog();
    _stopVadIdleWatcher();
    _cachedRemote = null;
    _boundPublicationSid = null;
    _remoteVoiceHot = false;
    await _stopMedia();
  }

  @override
  Future<void> detach() async {
    await _fullDetachMediaAndTimer();
    await _listener?.dispose();
    _listener = null;
    _room = null;
    _route = null;
  }

  @override
  void dispose() {
    unawaited(detach());
    super.dispose();
  }
}
