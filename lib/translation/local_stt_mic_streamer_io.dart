import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../services/call_audio.dart';
import '../services/debug_overlay.dart';
import '../services/stt/stt_service.dart';
import '../services/translation_api.dart';
import 'grok_mic_streamer_base.dart';
import 'grok_mic_streamer_io.dart' show createXaiMicStreamer;

/// Native (iOS/Android) SENDER-side pipeline, fully on-device for the STT step.
///
/// Replaces the x.ai WebSocket: instead of shipping mic PCM to a remote STT
/// proxy, the audio never leaves the phone. Only the recognised **text** goes
/// out, to the backend text-translation endpoint.
///
///   record (PCM16 16 kHz, system AEC) → VAD segmentation → Moonshine|Vosk
///     → fetchTextTranslation → onTranslation → peer synthesises with Kokoro
///
/// STT runs on the LOCAL outgoing mic, never the remote track, and that mic is
/// echo-cancelled — otherwise it would re-capture the translated voice coming
/// out of the loudspeaker and transcribe it as if the user had spoken it.
class LocalSttMicStreamer implements GrokMicStreamer {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;
  bool _running = false;
  bool _modelReady = false;
  bool _dozing = false;

  /// Set when on-device STT is unavailable and we hand the call back to the
  /// remote x.ai pipeline. Every member below then delegates to it.
  GrokMicStreamer? _fallback;

  String _sourceLang = '';
  String _targetLang = '';
  void Function(String orig, String trans, String lang, String audioB64)?
      _onTranslation;
  void Function(String error)? _onError;

  // Retained so the fallback can be started with the arguments we were given.
  Uri? _wsUrl;
  Object? _localTrack;
  void Function(String partial)? _onPartial;

  /// Accumulates the current utterance's samples in [-1, 1]. Clip engines only:
  /// a streaming engine holds this state inside its own decoder.
  final List<double> _utterance = [];
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
  String _lastPartial = '';

  // VAD (mean-square).
  //
  // For a STREAMING engine (Vosk) this no longer segments anything — Kaldi's own
  // endpointer does, via accept_waveform's return value. All it still does is
  // decide when the mic has been quiet long enough to release (doze), which is
  // purely a battery concern.
  //
  // For a CLIP engine (Moonshine) it is load-bearing: it is what decides when to
  // decode. The hangover is shorter than the x.ai streamer's 1.2 s because that
  // trailing silence would show up directly as latency.
  static const double _vadThreshold = 0.0002;
  static const int _silenceFlushMs = 700;

  /// After this much unbroken silence, release the microphone entirely. LiveKit
  /// is already capturing it for the call itself, so ours is a second, redundant
  /// capture that would otherwise convert and scan every buffer for minutes on
  /// end. [wake] restarts it on LiveKit's own speech signal.
  static const int _dozeAfterMs = 20000;

  static const int _sampleRate = 16000;
  static const int _minUtteranceSamples = _sampleRate ~/ 3; // ~333 ms
  static const int _maxUtteranceSamples = _sampleRate * 15;

  @override
  bool get isRunning => _fallback?.isRunning ?? _running;

  @override
  bool get isStreaming =>
      _fallback?.isStreaming ?? (_running && _modelReady && !_dozing);

  /// x.ai re-sends the growing session transcript; the on-device path emits
  /// independent utterances. The caller reads this per callback, so it tracks
  /// whichever pipeline is actually live.
  @override
  bool get accumulatesTranscript => _fallback?.accumulatesTranscript ?? false;

  @override
  bool get isDozing => _fallback?.isDozing ?? _dozing;

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

      if (!SttService.supportsLang(sourceLang)) {
        await _startFallback('unsupported_lang:$sourceLang');
        return;
      }

      // First call in a language downloads 30–60 MB. Capture starts anyway so
      // the call is never blocked on it; utterances are dropped until ready.
      unawaited(
        SttService.instance.ensureLanguageInstalled(sourceLang).then((_) async {
          _modelReady = SttService.instance.isReady;
          DebugOverlay.log('stt model ready=$_modelReady lang=$sourceLang');
          // Download failed, or the engine could not load — most often libvosk
          // missing on this platform. Hand the call to x.ai rather than let the
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

  /// Tear down our capture and run the remote x.ai streamer instead.
  Future<void> _startFallback(String reason) async {
    if (_fallback != null || !_running) return;
    DebugOverlay.log('stt fallback → x.ai ($reason)');

    await _audioSub?.cancel();
    _audioSub = null;
    _utterance.clear();
    try {
      await _rec.stop();
    } catch (_) {}

    final streamer = createXaiMicStreamer();
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
      autoGain: true,
    ));
    DebugOverlay.log('stt capture started — 16 kHz pcm16, aec/ns/agc on');
    _audioSub = stream.listen(
      (bytes) => _onPcm(bytes, _onTranslation!, _onError),
      onError: (Object e) => DebugOverlay.log('stt capture stream error: $e'),
      onDone: () => DebugOverlay.log('stt capture stream closed'),
    );
  }

  /// Release the mic after [_dozeAfterMs] of silence. Only [wake] revives it.
  Future<void> _doze() async {
    if (_dozing) return;
    _dozing = true;
    _utterance.clear();
    // 20 s of silence: a streaming decoder endpointed long ago, but reset so no
    // stale hypothesis survives the gap until wake().
    if (SttService.instance.isStreaming && _modelReady) {
      await SttService.instance.reset();
    }
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    DebugOverlay.log('stt dozing — mic released after ${_dozeAfterMs ~/ 1000}s silence');
  }

  @override
  Future<void> wake() async {
    if (_fallback != null) return; // x.ai never releases the mic
    if (!_running || !_dozing) return;
    _dozing = false;
    try {
      await _startCapture();
      DebugOverlay.log('stt woke — capture resumed');
    } catch (e) {
      _dozing = true;
      _onError?.call('wake_failed: $e');
    }
  }

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
    // Keep _lastVoiceMs fresh rather than just returning: it stops us flushing
    // the half-captured utterance we were holding, and it stops the doze timer.
    // Dozing here would be a trap — wake() is driven by LiveKit's
    // ActiveSpeakersChangedEvent, which never fires while its mic is disabled,
    // so a doze that began during mute would never be woken.
    if (isSendMuted || isTranslationPlaying) {
      if (!_gated) {
        _gated = true;
        _utterance.clear();
        // A streaming decoder is holding a half-decoded phrase. Drop it: the
        // words spoken over our own TTS are the barge-in we already gave up,
        // and letting them survive would splice them onto the next utterance.
        if (SttService.instance.isStreaming && _modelReady) {
          unawaited(SttService.instance.reset());
        }
      }
      _lastVoiceMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    _gated = false;

    final samples = _toFloat32(bytes);
    if (samples.isEmpty) return;

    final level = _meanSquare(samples);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final voiced = level > _vadThreshold;
    if (voiced) _lastVoiceMs = nowMs;

    if (++_frames % 100 == 0) {
      DebugOverlay.log('stt pcm frames=$_frames level=${level.toStringAsFixed(6)} '
          'voiced=$voiced ready=$_modelReady '
          'streaming=${SttService.instance.isStreaming} dozing=$_dozing');
    }

    // Streaming engine: hand every frame straight to the decoder. It endpoints
    // for itself, so nothing here segments; the VAD survives only to decide
    // when the mic has been quiet long enough to release.
    if (SttService.instance.isStreaming) {
      if (_modelReady) unawaited(_feed(samples, onTranslation, onError));
      if (nowMs - _lastVoiceMs >= _dozeAfterMs) unawaited(_doze());
      return;
    }

    // Buffer through the hangover window so trailing consonants aren't clipped;
    // outside it, silence is discarded rather than padding the utterance.
    if (voiced || nowMs - _lastVoiceMs < _silenceFlushMs) {
      _utterance.addAll(samples);
    }

    final speechEnded = _utterance.isNotEmpty &&
        !voiced &&
        nowMs - _lastVoiceMs >= _silenceFlushMs;
    if (speechEnded || _utterance.length >= _maxUtteranceSamples) {
      _flush(onTranslation, onError);
      return;
    }

    // Nothing pending and nobody has spoken for a while: stop burning CPU on a
    // capture LiveKit is already doing for the call.
    if (_utterance.isEmpty && nowMs - _lastVoiceMs >= _dozeAfterMs) {
      unawaited(_doze());
    }
  }

  void _flush(
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) {
    if (_utterance.length < _minUtteranceSamples) {
      _utterance.clear();
      return;
    }
    final samples = Float32List.fromList(_utterance);
    _utterance.clear();
    if (!_modelReady) return;

    unawaited(_recognizeAndTranslate(samples, onTranslation, onError));
  }

  /// Streaming path: one frame in, partials out, and a finished utterance
  /// whenever Kaldi's endpointer closes one.
  Future<void> _feed(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) async {
    try {
      final chunk = await SttService.instance.acceptFrame(samples);
      if (chunk.partial.isNotEmpty && chunk.partial != _lastPartial) {
        _lastPartial = chunk.partial;
        DebugOverlay.log('stt partial="${chunk.partial}"');
        _onPartial?.call(chunk.partial);
      }
      if (chunk.hasFinal) {
        _lastPartial = '';
        DebugOverlay.log('stt final="${chunk.finalText}" → translating');
        await _translateAndSend(chunk.finalText, onTranslation);
      }
    } catch (e) {
      onError?.call('stt:$e');
    }
  }

  /// Clip path (Moonshine): decode the whole VAD-clipped utterance at once.
  Future<void> _recognizeAndTranslate(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) async {
    try {
      final orig = await SttService.instance.transcribe(samples);
      if (orig.trim().isEmpty) return;
      DebugOverlay.log('stt orig="$orig"');
      await _translateAndSend(orig, onTranslation);
    } catch (e) {
      onError?.call('stt:$e');
    }
  }

  Future<void> _translateAndSend(
    String orig,
    void Function(String, String, String, String) onTranslation,
  ) async {
    final trans = await fetchTextTranslation(
      text: orig,
      from: _sourceLang,
      to: _targetLang,
    );
    if (trans.trim().isEmpty) {
      DebugOverlay.log('stt translate returned EMPTY ($_sourceLang→$_targetLang)');
      return;
    }

    // The round trip spans hundreds of ms. An utterance that closed just before
    // the user hit mute must not surface after it.
    if (isSendMuted) {
      DebugOverlay.log('stt drop: muted while translating');
      return;
    }
    DebugOverlay.log('stt send trans="$trans"');

    // audioB64 empty: no TTS is generated here. The peer receives the text as
    // a `kokoro` packet and synthesises it locally, in its own language.
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

  @override
  Future<void> stop() async {
    // The engine outlives this streamer (SttService caches the loaded model),
    // so leave its decoder clean for the next call rather than letting the last
    // half-utterance of this one prefix it.
    if (_modelReady && SttService.instance.isStreaming) {
      try {
        await SttService.instance.reset();
      } catch (_) {}
    }
    _running = false;
    _modelReady = false;
    _dozing = false;
    _gated = false;
    _utterance.clear();
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
