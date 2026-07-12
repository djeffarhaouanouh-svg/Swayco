import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../services/call_audio.dart';
import '../services/debug_overlay.dart';
import 'asr/asr_model_downloader.dart';
import 'asr/asr_service.dart';
import 'asr/whisper_hallucination.dart';
import '../services/translation_api.dart';
import 'sway_mic_streamer_base.dart';
import 'sway_mic_streamer_io.dart' show createCloudMicStreamer;

/// Native (iOS/Android) SENDER-side pipeline, fully on-device for the STT step.
///
/// Replaces the cloud engine WebSocket: instead of shipping mic PCM to a remote STT
/// proxy, the audio never leaves the phone. Only the recognised **text** goes
/// out, to the backend text-translation endpoint.
///
///   record (PCM16 16 kHz, system AEC) → VAD segmentation → neural|lattice
///     → fetchTextTranslation → onTranslation → peer synthesises with the local TTS engine
///
/// STT runs on the LOCAL outgoing mic, never the remote track, and that mic is
/// echo-cancelled — otherwise it would re-capture the translated voice coming
/// out of the loudspeaker and transcribe it as if the user had spoken it.
class LocalSttMicStreamer implements SwayMicStreamer {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;
  bool _running = false;
  bool _modelReady = false;


  /// Set when on-device STT is unavailable and we hand the call back to the
  /// remote the cloud engine pipeline. Every member below then delegates to it.
  SwayMicStreamer? _fallback;

  String _sourceLang = '';
  String _targetLang = '';
  void Function(String orig, String trans, String lang, String audioB64)?
      _onTranslation;
  void Function(String error)? _onError;

  // Retained so the fallback can be started with the arguments we were given.
  Uri? _wsUrl;
  Object? _localTrack;
  void Function(String partial)? _onPartial;

  /// Last frame that carried voice. The STREAMING engine's backstop only —
  /// Silero holds its own state for the clip engines.
  int _lastVoiceMs = 0;

  /// True while the mute / half-duplex gate is dropping audio. Edge-triggered so
  /// we reset the streaming decoder once on entry, not on every dropped frame.
  bool _gated = false;

  /// Frames seen since start. The web streamer logs this and it is the first
  /// thing you want when nothing is transcribed: it separates "the mic gives us
  /// nothing" from "the recogniser gives us nothing". On iOS `record` opens a
  /// SECOND capture of a mic LiveKit already holds, which is exactly the kind of
  /// failure that shows up as a silent, well-behaved stream of zeroes.
  int _frames = 0;

  /// Last partial we surfaced, so we don't log or re-emit an unchanged one.
  String _lastPartial = '';

  /// True while the decoder holds an un-closed hypothesis. Separate from
  /// [_lastPartial] on purpose: that one is display state, this one is the
  /// backstop's trigger, and conflating them made a stale partial re-arm a
  /// flush that then returned "" from an already-finalised recognizer.
  bool _hasPending = false;

  /// Every operation that touches the recognizer runs through this chain.
  /// `acceptFrame` and `flush` mutate the same native decoder, and both used to
  /// be fired unawaited from the audio callback — so they interleaved across
  /// their await points. Networked translation deliberately stays OFF the chain:
  /// awaiting an HTTP round trip here stalled the next utterance's flush, which
  /// is exactly why only the first sentence of a pair was ever sent.
  Future<void> _sttChain = Future.value();

  void _serialize(Future<void> Function() op) {
    _sttChain = _sttChain
        .then((_) => op())
        .catchError((Object e) => DebugOverlay.log('stt op error: $e'));
  }

  /// Silero VAD (sherpa-onnx) — what decides where a phrase begins and ends for
  /// a CLIP engine (Whisper, Moonshine). It replaced a mean-square energy
  /// threshold, which fired on doors, keyboards and breath, and could not tell
  /// speech from noise of the same loudness.
  ///
  /// It does its own min-speech and max-speech bounding, so the old
  /// `_minUtteranceSamples` / `_maxUtteranceSamples` guards are gone with it.
  sherpa.VoiceActivityDetector? _silero;
  static bool _sherpaBindingsReady = false;

  /// Silence that closes a phrase. Straight latency: nothing can be transcribed
  /// before it has elapsed.
  static const double _silenceSeconds = 0.3;

  /// A phrase this long is cut and sent whether or not the speaker paused —
  /// without it, a monologue would never reach the recogniser.
  static const double _maxSpeechSeconds = 15.0;

  /// Shorter than this is a cough, a click, a chair — and, crucially, a scrap of
  /// our own loudspeaker. Raised from 0.25 s: Whisper hallucinates in direct
  /// proportion to how little speech it is given, and a 250 ms fragment is
  /// exactly what it captions with subtitle boilerplate.
  static const double _minSpeechSeconds = 0.4;

  /// Silero's speech probability threshold (0..1). Above sherpa's 0.5 default:
  /// every marginal segment that squeaks past becomes a Whisper hallucination
  /// spoken out loud on the peer's phone, so the cost of a false positive here
  /// is far higher than the cost of missing a mumbled word.
  static const double _sileroThreshold = 0.6;

  /// Peak amplitude a segment must reach to be worth transcribing (0..1).
  ///
  /// The last line against our own echo. Silero says "this is speech" — and it
  /// is right, it IS speech: it is the translation coming out of our own
  /// loudspeaker, and Silero has no idea whose voice it is. But that residue,
  /// once AEC has had it and with AGC off, is far quieter than someone actually
  /// talking into the phone. Level is the one thing that still tells them apart.
  static const double _speechFloor = 0.06;

  /// Last transcript we accepted, and when. An identical one inside this window
  /// is our own translation coming back around, not the user saying it twice.
  String _lastOrig = '';
  int _lastOrigMs = 0;
  static const int _repeatWindowMs = 8000;

  // Kept for the STREAMING engine (Vosk) only, whose endpointer sometimes never
  // fires: if a hypothesis is pending and the mic has been quiet this long, we
  // force the close ourselves. Unused by the clip engines, which Silero segments.
  static const double _vadThreshold = 0.0002;
  static const int _silenceFlushMs = 700;

  static const int _sampleRate = 16000;

  @override
  bool get isRunning => _fallback?.isRunning ?? _running;

  @override
  bool get isStreaming => _fallback?.isStreaming ?? (_running && _modelReady);

  /// the cloud engine re-sends the growing session transcript; the on-device path emits
  /// independent utterances. The caller reads this per callback, so it tracks
  /// whichever pipeline is actually live.
  @override
  bool get accumulatesTranscript => _fallback?.accumulatesTranscript ?? false;

  /// The mic now stays open for the whole call — dozing (releasing it after 20 s
  /// of silence, to spare the battery) is gone. It cost the first syllable of
  /// every phrase that woke it, and Silero is cheap enough to run continuously.
  @override
  bool get isDozing => _fallback?.isDozing ?? false;

  @override
  Future<void> start({
    required Uri wsUrl, // unused: nothing is streamed off-device
    Object? localTrack,
    bool captureLocalMic = true,
    String sourceLang = '',
    String targetLang = '',
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    if (!captureLocalMic) {
      onError?.call('native_no_remote_capture');
      return;
    }
    if (sourceLang.isEmpty || targetLang.isEmpty) {
      onError?.call('no_route');
      return;
    }
    _sourceLang = sourceLang;
    _targetLang = targetLang;
    _onTranslation = onTranslation;
    _onError = onError;
    _onPartial = onPartial;
    _wsUrl = wsUrl;
    _localTrack = localTrack;
    _running = true;

    try {
      if (!await _rec.hasPermission()) {
        onError?.call('no_mic_permission');
        _running = false;
        return;
      }

      if (!AsrService.supportsLang(sourceLang)) {
        await _startFallback('unsupported_lang:$sourceLang');
        return;
      }

      // Silero (~2 MB) is fetched once and shared by every language. Without it
      // a clip engine has nothing to tell it where a phrase ends, so it would
      // never transcribe anything — hence the fallback.
      unawaited(_startSilero());

      // First call in a language downloads the model (Whisper small: ~357 MB).
      // Capture starts anyway so the call is never blocked on it; utterances are
      // dropped until ready.
      unawaited(
        AsrService.instance.ensureLanguageInstalled(sourceLang).then((_) async {
          _modelReady = AsrService.instance.isReady;
          DebugOverlay.log('stt model ready=$_modelReady lang=$sourceLang');
          // Download failed, or the engine could not load — most often libvosk
          // missing on this platform. Hand the call to the cloud engine rather than let the
          // user speak into a pipeline that will never answer.
          if (!_modelReady) await _startFallback('model_unavailable');
        }),
      );

      await _startCapture();
    } catch (e) {
      // record_ios throws here when inputNode.setVoiceProcessingEnabled() is
      // refused — which is what a clash with WebRTC's own VoiceProcessingIO on
      // the same mic looks like. Worth its own line: it is not an STT failure.
      DebugOverlay.log('stt START FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  /// Download Silero once and build the detector. Its buffer holds
  /// [_maxSpeechSeconds] plus a margin, so a long phrase is never truncated by
  /// the ring buffer before the VAD itself cuts it.
  Future<void> _startSilero() async {
    try {
      final model = await AsrModelDownloader.ensureSileroVad();
      if (!_running || _silero != null) return;
      if (!_sherpaBindingsReady) {
        sherpa.initBindings();
        _sherpaBindingsReady = true;
      }
      _silero = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: model,
            threshold: _sileroThreshold,
            minSilenceDuration: _silenceSeconds,
            minSpeechDuration: _minSpeechSeconds,
            maxSpeechDuration: _maxSpeechSeconds,
          ),
          sampleRate: _sampleRate,
          debug: false,
        ),
        bufferSizeInSeconds: _maxSpeechSeconds + 5,
      );
      DebugOverlay.log('stt silero VAD ready — '
          '${(_silenceSeconds * 1000).round()}ms silence closes a phrase');
    } catch (e) {
      DebugOverlay.log('stt silero FAILED: $e');
      await _startFallback('vad_unavailable');
    }
  }

  /// Tear down our capture and run the remote the cloud engine streamer instead.
  Future<void> _startFallback(String reason) async {
    if (_fallback != null || !_running) return;
    DebugOverlay.log('stt fallback → the cloud engine ($reason)');

    await _audioSub?.cancel();
    _audioSub = null;
    _freeSilero();
    try {
      await _rec.stop();
    } catch (_) {}

    final streamer = createCloudMicStreamer();
    _fallback = streamer;
    try {
      await streamer.start(
        wsUrl: _wsUrl!,
        localTrack: _localTrack,
        captureLocalMic: true,
        sourceLang: _sourceLang,
        targetLang: _targetLang,
        onTranslation: _onTranslation!,
        onPartial: _onPartial,
        onError: _onError,
      );
    } catch (e) {
      _fallback = null;
      _onError?.call('fallback_failed: $e');
    }
  }

  Future<void> _startCapture() async {
    _lastVoiceMs = DateTime.now().millisecondsSinceEpoch;
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      // AGC OFF. It was on, and it was actively harmful here: what AEC leaves of
      // the loudspeaker's own output is quiet — and AGC's whole job is to pull
      // quiet things up. It was handing Silero an amplified echo that looks like
      // speech, and Whisper captioned it. Without AGC the residue stays under
      // [_speechFloor] and never reaches the recogniser.
      autoGain: false,
    ));
    DebugOverlay.log('stt capture started — 16 kHz pcm16, aec+ns on, agc OFF');
    _audioSub = stream.listen(
      (bytes) => _onPcm(bytes, _onTranslation!, _onError),
      onError: (Object e) => DebugOverlay.log('stt capture stream error: $e'),
      onDone: () => DebugOverlay.log('stt capture stream closed'),
    );
  }

  /// The mic no longer dozes — it stays open for the whole call, so there is
  /// nothing to wake. Kept to satisfy [SwayMicStreamer]; the caller only ever
  /// calls it when [isDozing], which is now always false.
  @override
  Future<void> wake() async {}

  void _onPcm(
    Uint8List bytes,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) {
    // Two reasons to throw this buffer away rather than transcribe it:
    //
    //  isSendMuted        — the user muted. Muting the LiveKit track only
    //                       silences the raw voice; this is a separate
    //                       AudioRecorder, so without this the peer keeps
    //                       hearing the translation of everything they say.
    //  isTranslationPlaying — a translation is coming out of our own
    //                       loudspeaker. AEC alone has not proven enough here:
    //                       the TTS speaks the language our STT is listening
    //                       for, so any residual echo transcribes cleanly and
    //                       gets sent back to the peer, who answers it. Costs
    //                       barge-in: you cannot interrupt a translation.
    //
    // The gate is EDGE-triggered: on the closing edge, whatever Silero is
    // already holding was spoken BEFORE the gate shut — before the mute was
    // pressed, before our own TTS started. Those words were said out loud, on
    // purpose, to be heard, so they are flushed and published with `force`
    // (which is what gets them past the mute re-check in _translateAndSend).
    // Everything captured after the edge is simply not fed to the VAD.
    if (isSendMuted || isTranslationPlaying) {
      if (!_gated) {
        _gated = true;
        final gate = isSendMuted ? 'muted' : 'tts';
        DebugOverlay.log('stt gate CLOSED ($gate)');
        if (!_modelReady) {
          _silero?.reset();
        } else if (AsrService.instance.isStreaming) {
          DebugOverlay.log('stt gate — flushing what was already said');
          _serialize(() => _flushAndSend(onTranslation, force: true));
        } else {
          _flushSilero(onTranslation, force: true);
        }
      }
      _lastVoiceMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    if (_gated) {
      _gated = false;
      DebugOverlay.log('stt gate OPEN');
      // Silero kept scoring nothing while the gate was shut; drop whatever half
      // state it holds so the next phrase starts clean.
      _silero?.reset();
    }

    final samples = _toFloat32(bytes);
    if (samples.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Streaming engine (Vosk): it endpoints for itself — but not always.
    // Observed on device: partials build up and accept_waveform never returns 1,
    // so no utterance ever closes. The old mean-square VAD stays as its backstop.
    // Whisper is a clip engine, so this branch is unreachable today.
    if (AsrService.instance.isStreaming) {
      final voiced = _meanSquare(samples) > _vadThreshold;
      if (voiced) _lastVoiceMs = nowMs;
      if (_modelReady) {
        _serialize(() => _feed(samples, onTranslation, onError));
        if (_hasPending && !voiced && nowMs - _lastVoiceMs >= _silenceFlushMs) {
          // Claim it synchronously, before the flush is even queued: two silent
          // frames back to back would otherwise both queue one, and the second
          // returns "" from a recognizer already finalised.
          _hasPending = false;
          DebugOverlay.log('stt vad backstop: ${_silenceFlushMs}ms silence, forcing flush');
          _serialize(() => _flushAndSend(onTranslation));
        }
      }
      return;
    }

    // Clip engine (Whisper): Silero decides where phrases start and end. It
    // keeps its own pre-roll, so the first syllable is never clipped — which the
    // mean-square VAD, firing only once the level was already up, used to eat.
    final vad = _silero;
    if (vad == null) return; // still downloading — nothing to segment with

    vad.acceptWaveform(samples);
    if (++_frames % 100 == 0) {
      DebugOverlay.log('stt pcm frames=$_frames speaking=${vad.isDetected()} '
          'ready=$_modelReady');
    }
    _drainSilero(onTranslation, onError);
  }

  /// Hand every phrase Silero has closed to the recogniser.
  void _drainSilero(
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    bool force = false,
  }) {
    final vad = _silero;
    if (vad == null) return;
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      if (!_modelReady) continue; // model still downloading — drop the phrase
      final ms = (segment.samples.length / _sampleRate * 1000).round();
      final peak = _peak(segment.samples);

      // Too quiet to be someone talking INTO this phone. Silero is not wrong —
      // it is speech — but it is our own loudspeaker's, and handing it to Whisper
      // is how the peer ends up hearing sentences nobody said.
      if (peak < _speechFloor) {
        DebugOverlay.log('stt phrase ${ms}ms DROPPED — too quiet '
            '(peak ${peak.toStringAsFixed(3)} < $_speechFloor)');
        continue;
      }

      DebugOverlay.log(
          'stt phrase ${ms}ms peak=${peak.toStringAsFixed(3)} → transcribing');
      unawaited(_recognizeAndTranslate(
        segment.samples,
        onTranslation,
        onError,
        force: force,
      ));
    }
  }

  /// Loudest sample in the segment, 0..1.
  double _peak(Float32List samples) {
    var m = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > m) m = a;
    }
    return m;
  }

  /// Close whatever phrase Silero is mid-way through and send it. Used on the
  /// gate's closing edge, so the sentence a mute press interrupts still lands.
  void _flushSilero(
    void Function(String, String, String, String) onTranslation, {
    bool force = false,
  }) {
    final vad = _silero;
    if (vad == null) return;
    vad.flush();
    _drainSilero(onTranslation, _onError, force: force);
    vad.reset();
  }

  /// Streaming path: one frame in, partials out, and a finished utterance
  /// whenever the endpointer closes one.
  Future<void> _feed(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) async {
    try {
      final chunk = await AsrService.instance.acceptFrame(samples);
      if (chunk.partial.isNotEmpty) {
        _hasPending = true;
        if (chunk.partial != _lastPartial) {
          _lastPartial = chunk.partial;
          DebugOverlay.log('stt partial="${chunk.partial}"');
          _onPartial?.call(chunk.partial);
        }
      }
      if (chunk.hasFinal) {
        _hasPending = false;
        _lastPartial = '';
        DebugOverlay.log('stt final="${chunk.finalText}" → translating');
        // Off the chain: the HTTP round trip must not hold up the next frame.
        unawaited(_translateAndSend(chunk.finalText, onTranslation, onError));
      }
    } catch (e) {
      onError?.call('stt:$e');
    }
  }

  /// Close the utterance the streaming decoder is holding and ship it. Used by
  /// the VAD backstop and by the half-duplex gate; guarded because both can fire
  /// on the same frame and `flush` is destructive.
  Future<void> _flushAndSend(
    void Function(String, String, String, String) onTranslation, {
    bool force = false,
  }) async {
    final text = await AsrService.instance.flush();
    _lastPartial = '';
    _hasPending = false;
    if (text.trim().isEmpty) return;
    DebugOverlay.log('stt flushed="$text" → translating');
    // Off the chain, as in _feed: this awaits the backend.
    unawaited(_translateAndSend(text, onTranslation, _onError, force: force));
  }

  /// Clip path (neural): decode the whole VAD-clipped utterance at once.
  ///
  /// [force] publishes even though the gate has since closed — set it for the
  /// utterance the mute press itself interrupted (see the gate in [_onPcm]).
  Future<void> _recognizeAndTranslate(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    bool force = false,
  }) async {
    try {
      final orig = await AsrService.instance.transcribe(samples);
      final durationMs = (samples.length / _sampleRate * 1000).round();

      // Whisper captions silence and noise with subtitle boilerplate, and it
      // does it confidently. Unfiltered, the peer's phone says a sentence nobody
      // spoke, out loud, mid-conversation.
      if (looksHallucinated(orig, durationMs: durationMs)) {
        DebugOverlay.log('stt DROPPED hallucination: "$orig" (${durationMs}ms)');
        return;
      }

      // The same sentence twice in a row, seconds apart, is the recogniser
      // chewing on its own echo — not someone repeating themselves.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (orig == _lastOrig && nowMs - _lastOrigMs < _repeatWindowMs) {
        DebugOverlay.log('stt DROPPED repeat: "$orig"');
        return;
      }
      _lastOrig = orig;
      _lastOrigMs = nowMs;

      DebugOverlay.log('stt orig="$orig" (${durationMs}ms)');
      await _translateAndSend(orig, onTranslation, onError, force: force);
    } catch (e) {
      onError?.call('stt:$e');
    }
  }

  /// [force] publishes even if the mic is muted by the time the backend answers.
  /// Set it for a flush triggered *by* the mute: those words predate the press.
  Future<void> _translateAndSend(
    String orig,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError, {
    bool force = false,
  }) async {
    final String trans;
    try {
      trans = await fetchTextTranslation(
        text: orig,
        from: _sourceLang,
        to: _targetLang,
      );
    } catch (e) {
      DebugOverlay.log('stt translate FAILED ($_sourceLang→$_targetLang): $e');
      onError?.call('translate:$e');
      return;
    }
    if (trans.trim().isEmpty) {
      DebugOverlay.log('stt translate returned EMPTY ($_sourceLang→$_targetLang)');
      return;
    }

    // Audio captured *after* the mute must never surface. Audio captured before
    // it must — the user said those words out loud, intending to be heard, and
    // the round trip merely spans hundreds of ms.
    if (isSendMuted && !force) {
      DebugOverlay.log('stt drop: muted while translating');
      return;
    }
    DebugOverlay.log('stt send trans="$trans"');

    // audioB64 empty: no TTS is generated here. The peer receives the text as
    // a local-TTS packet and synthesises it locally, in its own language.
    onTranslation(orig, trans, _targetLang, '');
  }

  Float32List _toFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  double _meanSquare(Float32List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    return sum / samples.length;
  }

  /// Silero is native memory — it has to be freed by hand, and never used again
  /// after (a second free, or a use-after-free, takes the whole app down).
  void _freeSilero() {
    final vad = _silero;
    _silero = null;
    try {
      vad?.free();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    // The engine outlives this streamer (AsrService caches the loaded model),
    // so leave its decoder clean for the next call rather than letting the last
    // half-utterance of this one prefix it.
    if (_modelReady && AsrService.instance.isStreaming) {
      try {
        await AsrService.instance.reset();
      } catch (_) {}
    }
    _running = false;
    _modelReady = false;
    _gated = false;
    _hasPending = false;
    _lastPartial = '';
    _freeSilero();
    _onTranslation = null;
    _onError = null;
    _onPartial = null;
    final fallback = _fallback;
    _fallback = null;
    if (fallback != null) {
      try {
        await fallback.stop();
      } catch (_) {}
    }
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _rec.stop();
    } catch (_) {}
  }
}
