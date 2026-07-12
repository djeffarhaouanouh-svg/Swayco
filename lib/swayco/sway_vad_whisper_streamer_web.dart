/// TEST — non-streaming STT: Silero VAD (in the browser) + Whisper (backend).
/// WEB ONLY, MEANT TO BE REVERTED.
///
/// Replaces the continuous PCM-over-WebSocket streamer for the duration of the
/// experiment. The trade it makes:
///
///   mic open for the whole call
///        ↓
///   Silero v5 listens (frames of 512 samples @ 16 kHz)
///        ↓
///   "Bonjour…"  → speech starts (with 500 ms of pre-roll, so the first
///                 syllable is never clipped)
///        ↓
///   300 ms of silence → the utterance is closed and clipped
///        ↓
///   only that segment goes to Whisper → translation → peer
///
/// Nothing leaves the browser while the user is silent, and Whisper sees a whole
/// phrase at once instead of guessing word by word. The cost is latency: no
/// translation can start before the phrase has ended.
///
/// The VAD comes from `@ricky0123/vad-web`, loaded from the CDN in
/// `web/index.html` (it exposes `window.vad`).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../services/call_audio.dart';
import '../services/debug_overlay.dart';
import '../services/translation_api.dart';
import 'sway_mic_streamer_base.dart';

SwayMicStreamer createSwayMicStreamer() => _VadWhisperStreamer();

void _log(String m) {
  web.console.log('[vad-whisper] $m'.toJS);
  DebugOverlay.log('[vad] $m');
}

// ── window.vad (@ricky0123/vad-web 0.0.29) ────────────────────────────────
@JS('vad')
external _VadNamespace? get _vad;

extension type _VadNamespace(JSObject _) implements JSObject {
  // ignore: non_constant_identifier_names — the JS class is named MicVAD.
  external _MicVadClass get MicVAD;
}

extension type _MicVadClass(JSObject _) implements JSObject {
  /// `MicVAD.new(options)` — a static factory literally named `new`.
  @JS('new')
  external JSPromise<_MicVad> create(_MicVadOptions options);
}

extension type _MicVad(JSObject _) implements JSObject {
  external void start();
  external void pause();
}

/// `{ isSpeech, notSpeech }` — Silero's per-frame verdict, 0..1.
extension type _VadProbs(JSObject _) implements JSObject {
  external double get isSpeech;
}

extension type _MicVadOptions._(JSObject _) implements JSObject {
  external factory _MicVadOptions({
    JSFunction getStream,
    JSFunction onSpeechStart,
    JSFunction onSpeechEnd,
    JSFunction onVADMisfire,
    JSFunction onFrameProcessed,
    String model,
    double positiveSpeechThreshold,
    double negativeSpeechThreshold,
    int redemptionMs,
    int preSpeechPadMs,
    int minSpeechMs,
    String baseAssetPath,
    String onnxWASMBasePath,
  });
}

const String _kVadAssets =
    'https://cdn.jsdelivr.net/npm/@ricky0123/vad-web@0.0.29/dist/';
const String _kOrtAssets =
    'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/';

class _VadWhisperStreamer implements SwayMicStreamer {
  _MicVad? _vadInstance;
  web.MediaStream? _micStream;
  bool _ownsMicStream = false;

  bool _running = false;
  bool _ready = false;
  int _segments = 0;

  /// Silero diagnostics: highest score seen since the last report, and the
  /// frame counter that paces those reports.
  double _peak = 0;
  int _frames = 0;

  String _from = '';
  String _to = '';
  void Function(String orig, String trans, String lang, String audioB64)?
      _cbTranslation;
  void Function(String error)? _cbError;

  /// Whisper calls are chained, never run in parallel: two overlapping segments
  /// would race and the peer could hear the second sentence before the first.
  Future<void> _queue = Future<void>.value();

  @override
  bool get isRunning => _running;

  @override
  bool get isStreaming => _running && _ready;

  /// Each callback is one independent VAD-clipped utterance, so the caller must
  /// NOT apply the streaming path's delta/dedup logic.
  @override
  bool get accumulatesTranscript => false;

  /// The mic stays open for the entire call — that is the point of the test.
  @override
  bool get isDozing => false;

  @override
  Future<void> wake() async {}

  @override
  Future<void> start({
    required Uri wsUrl, // unused: this path is HTTP, not WebSocket
    Object? localTrack,
    bool captureLocalMic = true,
    String sourceLang = '',
    String targetLang = '',
    required void Function(
            String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    if (_running) return;
    _running = true;
    _from = sourceLang;
    _to = targetLang;
    _cbTranslation = onTranslation;
    _cbError = onError;

    if (_vad == null) {
      _log('window.vad missing — is the CDN script tag in web/index.html?');
      onError?.call('vad_not_loaded');
      _running = false;
      return;
    }

    try {
      final stream = await _acquireMic(localTrack);
      if (stream == null) {
        onError?.call('no_mic');
        _running = false;
        return;
      }
      _micStream = stream;

      final vad = await _vad!.MicVAD
          .create(_MicVadOptions(
            // Hand the VAD the mic we already have instead of letting it open a
            // second getUserMedia: this stream is a clone of the track LiveKit
            // publishes, so it carries the browser's AEC. Without that, the VAD
            // hears the peer's voice coming out of the speaker and we translate
            // our own output back to them.
            getStream: (() => Future<web.MediaStream>.value(stream).toJS).toJS,
            model: 'v5',
            // The user asked for 300 ms of silence to close a phrase.
            redemptionMs: 300,
            // Silero needs a few frames to be sure speech started. Without
            // pre-roll the first syllable would be cut, so re-attach the half
            // second that precedes the trigger — the mic is always open, that
            // buffer is always there.
            preSpeechPadMs: 500,
            // Shorter than this is a cough, a click, a chair.
            minSpeechMs: 200,
            // The library defaults. An earlier 0.5/0.35 — "a call is noisy, and
            // every false positive costs a Whisper round-trip" — misfired on
            // EVERY utterance: with AGC off the mic is quiet, Silero's score
            // hovers near 0.4, so it crossed 0.5 for a frame or two, fell back
            // under 0.35, and the 300 ms window closed before 200 ms of speech
            // had accumulated. Tighten these again only with the peak-score log
            // below in hand.
            positiveSpeechThreshold: 0.3,
            negativeSpeechThreshold: 0.25,
            onSpeechStart: (() => _log('speech start')).toJS,
            onVADMisfire: (() {
              _log('misfire — speech shorter than 200ms, dropped '
                  '(peak score ${_peak.toStringAsFixed(2)})');
              _peak = 0;
            }).toJS,
            // Silero's score on every frame (32 ms). We only surface the peak,
            // every ~3 s: it is the one number that says whether the thresholds
            // are wrong or the mic is simply too quiet.
            onFrameProcessed: ((_VadProbs p, JSFloat32Array _) {
              if (p.isSpeech > _peak) _peak = p.isSpeech;
              if (++_frames % 100 == 0) {
                _log('peak score over last 3s: ${_peak.toStringAsFixed(2)} '
                    '(speech starts at 0.30)');
                _peak = 0;
              }
            }).toJS,
            onSpeechEnd: ((JSFloat32Array audio) {
              _onSegment(audio.toDart);
            }).toJS,
            baseAssetPath: _kVadAssets,
            onnxWASMBasePath: _kOrtAssets,
          ))
          .toDart;

      if (!_running) {
        // stop() landed while the model was downloading.
        vad.pause();
        return;
      }
      _vadInstance = vad;
      vad.start();
      _ready = true;
      _log('Silero v5 listening — redemption 300ms, pad 500ms, $_from→$_to');
    } catch (e) {
      _log('start FAILED: $e');
      onError?.call('start_failed: $e');
      await stop();
    }
  }

  /// The LiveKit track, cloned. Falls back to our own getUserMedia only when
  /// LiveKit hasn't published yet — same constraints either way (AEC on, NS on,
  /// AGC off; AGC would amplify any speaker leak until the audio runs away).
  Future<web.MediaStream?> _acquireMic(Object? localTrack) async {
    web.MediaStreamTrack? lkTrack;
    if (localTrack != null) {
      try {
        final fwTrack = (localTrack as dynamic).mediaStreamTrack;
        lkTrack = (fwTrack as dynamic).jsTrack as web.MediaStreamTrack?;
      } catch (_) {}
    }

    if (lkTrack != null) {
      final stream = web.MediaStream();
      stream.addTrack(lkTrack.clone());
      _ownsMicStream = true;
      _log('LiveKit track cloned (AEC on, NS on, AGC off)');
      return stream;
    }

    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(
          audio: web.MediaTrackConstraints(
            echoCancellation: true.toJS,
            noiseSuppression: true.toJS,
            autoGainControl: false.toJS,
          ),
        ))
        .toDart;
    if (stream.getAudioTracks().toDart.isEmpty) {
      _log('getUserMedia returned no audio track');
      return null;
    }
    _ownsMicStream = true;
    _log('getUserMedia fallback (LiveKit track not published yet)');
    return stream;
  }

  /// One finished utterance, 16 kHz mono float. Whisper it, translate it, hand
  /// the text back to the caller, which publishes it on the data channel.
  void _onSegment(Float32List samples) {
    if (!_running || samples.isEmpty) return;

    // Two reasons to throw a segment away rather than translate it:
    //
    //  isSendMuted          — the user muted.
    //  isTranslationPlaying — a translation is coming out of our own speaker.
    //                         AEC alone is not enough: the TTS speaks the very
    //                         language our STT listens for, so residual echo
    //                         transcribes cleanly and we send the peer their own
    //                         translation back. The native pipeline gates on this
    //                         for exactly that reason.
    //
    // This flag cannot stick: it clears itself 800 ms after playback (see
    // call_audio_web.dart), and a second translation will not re-arm a timer
    // that is already running. The standing "never gate SEND on
    // isTranslationPlaying" rule was about the STREAMING path, where cloud TTS
    // arrived continuously and held the flag up for the rest of the call. Here
    // segments are discrete, so the gate is bounded by construction.
    if (isSendMuted || isTranslationPlaying) {
      _log('segment dropped — ${isSendMuted ? 'mic muted' : 'our speaker is playing a translation'}');
      return;
    }

    final durationMs = (samples.length / 16000 * 1000).round();
    final wav = _encodeWav16kMono(samples);
    final seq = ++_segments;
    _log('segment #$seq ${durationMs}ms → ${wav.length ~/ 1024}KB');

    final queuedAt = DateTime.now();
    _queue = _queue.then((_) async {
      if (!_running) return;
      final sentAt = DateTime.now();
      final waited = sentAt.difference(queuedAt).inMilliseconds;
      final res = await fetchWhisperTranslation(
        wavBytes: wav,
        from: _from,
        to: _to,
      );
      if (!_running) return;
      final roundTrip = DateTime.now().difference(sentAt).inMilliseconds;
      if (res == null) {
        _log('segment #$seq → nothing (silence, or backend refused)');
        return;
      }
      // Muted while the backend was answering: these words predate the press,
      // but the user has since asked not to be heard. Native drops them too.
      if (isSendMuted) {
        _log('segment #$seq dropped — muted while translating');
        return;
      }
      // Latency the peer actually feels: 300 ms of VAD redemption, plus the
      // queue wait, plus the round-trip. Their TTS starts right after this.
      _log('segment #$seq "${res.orig}" → "${res.trans}" | '
          'vad=300ms queue=${waited}ms stt=${res.sttMs}ms '
          'trad=${res.translateMs}ms net=${roundTrip - res.sttMs - res.translateMs}ms '
          'TOTAL=${300 + waited + roundTrip}ms');
      _cbTranslation?.call(res.orig, res.trans, res.lang, '');
    }).catchError((Object e) {
      _log('segment #$seq FAILED: $e');
      _cbError?.call('whisper:$e');
    });
  }

  /// Float32 @16 kHz → 16-bit PCM WAV. Whisper wants a real container, and this
  /// is the cheapest one to build (44-byte header, no encoder).
  Uint8List _encodeWav16kMono(Float32List samples) {
    const int sampleRate = 16000;
    final int dataBytes = samples.length * 2;
    final bytes = Uint8List(44 + dataBytes);
    final view = ByteData.view(bytes.buffer);

    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little); // PCM chunk size
    view.setUint16(20, 1, Endian.little); // format = PCM
    view.setUint16(22, 1, Endian.little); // mono
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    view.setUint16(32, 2, Endian.little); // block align
    view.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    view.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i].clamp(-1.0, 1.0);
      view.setInt16(
          44 + i * 2, (s < 0 ? s * 32768 : s * 32767).round(), Endian.little);
    }
    return bytes;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _ready = false;
    try {
      _vadInstance?.pause();
    } catch (_) {}
    _vadInstance = null;
    // Only ever our own clone — never the track LiveKit is using for the call.
    if (_ownsMicStream) {
      try {
        for (final t in _micStream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
          t.stop();
        }
      } catch (_) {}
    }
    _micStream = null;
    _ownsMicStream = false;
    _cbTranslation = null;
    _cbError = null;
  }
}
