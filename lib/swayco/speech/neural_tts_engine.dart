import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'tts_audio_context.dart';
import 'voice_clone_service.dart';

/// The on-device TTS engine, on the runtime's `OfflineTts` (neural: neural).
///
/// **Runs in a background isolate.** `OfflineTts` creation loads an ONNX session
/// and `generate` synthesises — both are blocking native calls. On the main
/// isolate they froze the UI (at launch while configuring, and per utterance
/// during a call). The native engine therefore lives in a spawned isolate; the
/// main isolate only sends text and receives PCM, then plays it. The `OfflineTts`
/// pointer never crosses the isolate boundary (it can't), so the whole engine
/// lifecycle happens inside the worker.
///
/// Public surface (`configure` / `isReady` / `speak` / `onPlaybackComplete` /
/// `stop` / `dispose`) is unchanged, so `SpeechService` is untouched.

/// The files a configured neural voice needs on disk: the `.onnx` model, its
/// `tokens.txt`, and the the phonemiser data directory.
class NeuralTtsModel {
  const NeuralTtsModel({
    required this.model,
    required this.tokens,
    required this.dataDir,
  });

  final String model;
  final String tokens;
  final String dataDir;

  Map<String, dynamic> toMap() => {
        'model': model,
        'tokens': tokens,
        'dataDir': dataDir,
      };

  static NeuralTtsModel fromMap(Map<String, dynamic> m) => NeuralTtsModel(
        model: m['model'] as String,
        tokens: m['tokens'] as String,
        dataDir: m['dataDir'] as String,
      );
}

class NeuralTtsEngine {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  /// The single in-flight request (configure or speak). Both are serialised by
  /// the caller (SpeechService awaits configure; speak drops while inferring),
  /// so one pending completer is enough.
  Completer<List<dynamic>>? _pending;

  final AudioPlayer _player = AudioPlayer();
  bool _configured = false;
  bool _inferring = false;

  Future<void> _ensureSpawned() async {
    if (_isolate != null) return;
    final rp = ReceivePort();
    _fromWorker = rp;
    final handshake = Completer<SendPort>();
    rp.listen((msg) {
      if (msg is SendPort) {
        handshake.complete(msg);
        return;
      }
      final p = _pending;
      _pending = null;
      p?.complete(msg as List<dynamic>);
    });
    _isolate = await Isolate.spawn(_ttsWorkerMain, rp.sendPort);
    _toWorker = await handshake.future;
  }

  /// Build the native engine for [m] in the worker isolate. Awaits the build but
  /// does not block the UI thread.
  Future<void> configure(NeuralTtsModel m) async {
    await _ensureSpawned();
    final c = Completer<List<dynamic>>();
    _pending = c;
    _toWorker!.send(['configure', m.toMap()]);
    final res = await c.future;
    if (res.isEmpty || res[0] != 'configured') {
      _configured = false;
      throw StateError(
          'sherpa TTS configure failed: ${res.length > 1 ? res[1] : "?"}');
    }
    // Route playback like flutter_tts (the call's voice route), not the media
    // route a bare AudioPlayer would use.
    await applyCallTtsAudioContext(_player);
    _configured = true;
  }

  bool get isReady => _configured;

  /// Synthesise [text] in the worker and play the returned PCM. Returns as soon
  /// as playback *starts*. Overlapping calls are dropped, matching the old
  /// player: a stale utterance decoded late would land after the one after it.
  Future<void> speak(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    if (!_configured) throw StateError('sherpa TTS not configured');
    if (_inferring) return;
    if (text.trim().isEmpty) return;
    _inferring = true;

    try {
      final c = Completer<List<dynamic>>();
      _pending = c;
      _toWorker!.send(['speak', text, sid, speed]);
      final res = await c.future;
      if (res.isEmpty || res[0] != 'audio') return;
      var samples = res[1] as Float32List;
      var sampleRate = res[2] as int;
      if (samples.isEmpty) return;

      // The peer hears their OWN voice, not this stock one — the whole point of
      // docs/voice-cloning.md. It lands here because this is the only place the
      // synthesised audio exists as samples before it becomes a file: the
      // converter needs audio, not text. Returns null whenever the feature is
      // not available (no models, no peer fingerprint yet, conversion failed),
      // and then we play exactly what we synthesised — it must never be the
      // reason a sentence goes unspoken.
      final revoiced = VoiceCloneService.instance.revoiceAsPeer(
        samples,
        sampleRate,
      );
      if (revoiced != null) {
        samples = revoiced.pcm;
        sampleRate = revoiced.sampleRate;
      }

      final wav = _float32ToWav(samples, sampleRate);
      final tmp = await getTemporaryDirectory();
      final wavFile = File('${tmp.path}/speech_out.wav');
      await wavFile.writeAsBytes(wav);

      await _player.stop();
      await _player.play(DeviceFileSource(wavFile.path));
    } finally {
      _inferring = false;
    }
  }

  /// Fires when the current utterance finishes playing — the in-call half-duplex
  /// gate listens here (see [SpeechService.onPlaybackComplete]).
  Stream<void> get onPlaybackComplete => _player.onPlayerComplete;

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
    _toWorker?.send(['dispose']);
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _fromWorker?.close();
    _fromWorker = null;
    _toWorker = null;
    _configured = false;
  }

  // ── WAV conversion (main isolate) ───────────────────────────────────────────
  // sherpa returns mono float32 in [-1, 1]; audioplayers wants a container.

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

// ─────────────────────────── Worker isolate ───────────────────────────────────
// Owns the OfflineTts. initBindings() must run here too — the FFI bindings are
// per-isolate. All native calls (create + generate) happen on this isolate, so
// nothing blocks the UI. Only Float32List PCM crosses back.

void _ttsWorkerMain(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);

  var bindingsReady = false;
  sherpa.OfflineTts? tts;

  rp.listen((message) {
    final msg = message as List<dynamic>;
    switch (msg[0] as String) {
      case 'configure':
        try {
          if (!bindingsReady) {
            sherpa.initBindings();
            bindingsReady = true;
          }
          final m =
              NeuralTtsModel.fromMap((msg[1] as Map).cast<String, dynamic>());
          tts?.free();
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(model: _buildModelConfig(m)),
          );
          toMain.send(['configured']);
        } catch (e) {
          tts = null;
          toMain.send(['error', e.toString()]);
        }
        break;
      case 'speak':
        try {
          final engine = tts;
          if (engine == null) {
            toMain.send(['error', 'not configured']);
            break;
          }
          final audio = engine.generate(
            text: msg[1] as String,
            sid: msg[2] as int,
            speed: msg[3] as double,
          );
          toMain.send(['audio', audio.samples, audio.sampleRate]);
        } catch (e) {
          toMain.send(['error', e.toString()]);
        }
        break;
      case 'dispose':
        tts?.free();
        tts = null;
        rp.close();
        break;
    }
  });
}

sherpa.OfflineTtsModelConfig _buildModelConfig(NeuralTtsModel m) {
  return sherpa.OfflineTtsModelConfig(
    vits: sherpa.OfflineTtsVitsModelConfig(
      model: m.model,
      tokens: m.tokens,
      dataDir: m.dataDir,
    ),
    numThreads: 2,
    debug: false,
    provider: 'cpu',
  );
}
