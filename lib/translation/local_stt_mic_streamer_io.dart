import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

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

  /// Accumulates the current utterance's samples in [-1, 1].
  final List<double> _utterance = [];
  int _lastVoiceMs = 0;

  // VAD (mean-square). Same threshold as the x.ai streamer; the hangover is
  // shorter because it now decides when to *decode*, not merely when to send —
  // 1.2 s of trailing silence would show up directly as latency.
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
    _audioSub = stream.listen(
      (bytes) => _onPcm(bytes, _onTranslation!, _onError),
    );
  }

  /// Release the mic after [_dozeAfterMs] of silence. Only [wake] revives it.
  Future<void> _doze() async {
    if (_dozing) return;
    _dozing = true;
    _utterance.clear();
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
    final samples = _toFloat32(bytes);
    if (samples.isEmpty) return;

    final level = _meanSquare(samples);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final voiced = level > _vadThreshold;
    if (voiced) _lastVoiceMs = nowMs;

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

  Future<void> _recognizeAndTranslate(
    Float32List samples,
    void Function(String, String, String, String) onTranslation,
    void Function(String)? onError,
  ) async {
    try {
      final orig = await SttService.instance.transcribe(samples);
      if (orig.trim().isEmpty) return;
      DebugOverlay.log('stt orig="$orig"');

      final trans = await fetchTextTranslation(
        text: orig,
        from: _sourceLang,
        to: _targetLang,
      );
      if (trans.trim().isEmpty) return;

      // audioB64 empty: no TTS is generated here. The peer receives the text as
      // a `kokoro` packet and synthesises it locally, in its own language.
      onTranslation(orig, trans, _targetLang, '');
    } catch (e) {
      onError?.call('stt:$e');
    }
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
    _running = false;
    _modelReady = false;
    _dozing = false;
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
