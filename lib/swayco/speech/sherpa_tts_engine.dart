import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// The on-device TTS engine, on sherpa-onnx's `OfflineTts`.
///
/// One engine, many model families: Kokoro and Piper/VITS differ only by which
/// config field is filled ([SwayTtsEngineKind]). That is the whole point of
/// moving here — the phonemiser (espeak-ng) and tokeniser live inside the
/// native runtime, so the app no longer hand-rolls IPA per language.
///
/// The app installs exactly one language (STT reads the phone's own mic, TTS
/// speaks the peer's language), so a device configures a single [OfflineTts].
///
/// Replaces the Kokoro-only `TtsPlayer`; it keeps the same public surface
/// (`isReady` / `speak` / `onPlaybackComplete` / `stop` / `dispose`) so
/// `SpeechService` swaps engines without changing its callers.
enum SwayTtsEngineKind { kokoro, vits }

/// The files a configured engine needs on disk. Which fields matter depends on
/// [kind]: Kokoro reads [voices]; VITS/Piper does not. [dataDir] is the shared
/// espeak-ng data (bundled once as an asset), [lexicon] is optional per model.
class SherpaTtsModel {
  const SherpaTtsModel({
    required this.kind,
    required this.model,
    required this.tokens,
    required this.dataDir,
    this.voices = '',
    this.lexicon = '',
    this.lang = '',
  });

  final SwayTtsEngineKind kind;
  final String model;
  final String tokens;
  final String dataDir;
  final String voices; // Kokoro only
  final String lexicon; // optional
  final String lang; // Kokoro language hint, optional
}

class SherpaTtsEngine {
  static bool _bindingsReady = false;

  sherpa.OfflineTts? _tts;
  final AudioPlayer _player = AudioPlayer();
  bool _inferring = false;

  /// Build the native engine for [m]. Synchronous native session creation
  /// (~1–3 s), so call it from a loading state, not from build().
  Future<void> configure(SherpaTtsModel m) async {
    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }

    final modelConfig = switch (m.kind) {
      SwayTtsEngineKind.kokoro => sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: m.model,
            voices: m.voices,
            tokens: m.tokens,
            dataDir: m.dataDir,
            lexicon: m.lexicon,
            lang: m.lang,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
      SwayTtsEngineKind.vits => sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: m.model,
            tokens: m.tokens,
            dataDir: m.dataDir,
            lexicon: m.lexicon,
          ),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
    };

    // Rebuild cleanly if a previous engine was resident.
    _tts?.free();
    _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig));
  }

  bool get isReady => _tts != null;

  /// Synthesise [text] and play it. Returns as soon as playback *starts*.
  ///
  /// [sid] selects a built-in speaker (voice) for multi-speaker models; [speed]
  /// scales tempo. Overlapping calls are dropped rather than queued, matching
  /// the old player: a stale utterance decoded late would land after the one
  /// that followed it.
  Future<void> speak(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    final tts = _tts;
    if (tts == null) throw StateError('sherpa TTS not configured');
    if (_inferring) return;
    if (text.trim().isEmpty) return;
    _inferring = true;

    try {
      // generate() is a blocking native call on the calling isolate. Utterances
      // here are short (one translated phrase), so the hitch is small; a
      // dedicated isolate is a later optimisation (the OfflineTts pointer cannot
      // cross isolate boundaries, so it would need its own engine instance).
      final audio = tts.generate(text: text, sid: sid, speed: speed);
      final samples = audio.samples;
      if (samples.isEmpty) return;

      final wav = _float32ToWav(samples, audio.sampleRate);
      final tmp = await getTemporaryDirectory();
      final wavFile = File('${tmp.path}/speech_out.wav');
      await wavFile.writeAsBytes(wav);

      await _player.stop();
      await _player.play(DeviceFileSource(wavFile.path));
    } finally {
      _inferring = false;
    }
  }

  /// Fires when the current utterance finishes playing — the in-call
  /// half-duplex gate listens here (see [SpeechService.onPlaybackComplete]).
  Stream<void> get onPlaybackComplete => _player.onPlayerComplete;

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
    _tts?.free();
    _tts = null;
  }

  // ── WAV conversion ─────────────────────────────────────────────────────────
  // sherpa hands back mono float32 in [-1, 1] at the model's sample rate;
  // audioplayers wants a container, so wrap it in a 16-bit PCM WAV.

  static Uint8List _float32ToWav(Float32List samples, int sampleRate) {
    final numSamples = samples.length;
    final data = ByteData(44 + numSamples * 2);
    var o = 0;

    void setUint8(int v) => data.setUint8(o++, v);
    void setU16(int v) { data.setUint16(o, v, Endian.little); o += 2; }
    void setU32(int v) { data.setUint32(o, v, Endian.little); o += 4; }

    setUint8(0x52); setUint8(0x49); setUint8(0x46); setUint8(0x46); // "RIFF"
    setU32(36 + numSamples * 2);
    setUint8(0x57); setUint8(0x41); setUint8(0x56); setUint8(0x45); // "WAVE"
    setUint8(0x66); setUint8(0x6D); setUint8(0x74); setUint8(0x20); // "fmt "
    setU32(16);
    setU16(1); // PCM
    setU16(1); // mono
    setU32(sampleRate);
    setU32(sampleRate * 2);
    setU16(2);
    setU16(16);
    setUint8(0x64); setUint8(0x61); setUint8(0x74); setUint8(0x61); // "data"
    setU32(numSamples * 2);
    for (var i = 0; i < numSamples; i++) {
      final s = samples[i].clamp(-1.0, 1.0);
      data.setInt16(o, (s * 32767).round(), Endian.little);
      o += 2;
    }
    return data.buffer.asUint8List();
  }
}
