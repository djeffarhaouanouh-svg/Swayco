import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'tts_audio_context.dart';

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

  /// The single in-flight request (configure or synthesise). Both are
  /// serialised — SpeechService awaits configure, [_synthQueue] lines the
  /// syntheses up — so one pending completer is enough.
  Completer<List<dynamic>>? _pending;

  final AudioPlayer _player = AudioPlayer();
  bool _configured = false;

  /// Le nom de fichier courant, tourné à chaque phrase (voir [_synthesiseOne]).
  int _slot = 0;

  /// Les synthèses se suivent une par une : le worker n'a qu'un moteur.
  Future<void> _synthQueue = Future<void>.value();

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

  /// Synthesise [text] and play it. Returns as soon as playback *starts*.
  ///
  /// Kept as one call for the places that just want a voice (a preview in the
  /// settings). In a call the two halves are driven separately — see
  /// [synthesiseToFile] — so the next sentence can be synthesised while the
  /// current one is still being heard.
  Future<void> speak(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) async {
    final path = await synthesiseToFile(text, sid: sid, speed: speed);
    if (path == null) return;
    await playFile(path);
  }

  /// Synthesise [text] to a WAV on disk and return its path — nothing is
  /// played. Null when there was nothing to synthesise.
  ///
  /// Calls QUEUE rather than drop. Dropping was the old behaviour and it was
  /// silent: a sentence overtaken by the next simply never existed. Now that
  /// the caller can start the next synthesis while the current one plays, an
  /// overlap is the normal case, not an accident.
  Future<String?> synthesiseToFile(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) {
    if (!_configured) throw StateError('sherpa TTS not configured');
    if (text.trim().isEmpty) return Future<String?>.value();
    // Le worker n'a qu'un moteur : deux synthèses en même temps se
    // marcheraient dessus sur le [_pending] partagé. On les met à la queue leu
    // leu, sans en perdre.
    final job = _synthQueue.then((_) => _synthesiseOne(text, sid, speed));
    _synthQueue = job.then((_) {}, onError: (_) {});
    return job;
  }

  Future<String?> _synthesiseOne(String text, int sid, double speed) async {
    {
      final c = Completer<List<dynamic>>();
      _pending = c;
      _toWorker!.send(['speak', text, sid, speed]);
      final res = await c.future;
      if (res.isEmpty || res[0] != 'audio') return null;
      final wav = res[1] as Uint8List;
      if (wav.isEmpty) return null;

      final tmp = await getTemporaryDirectory();
      // Un nom qui tourne sur quatre, jamais le même deux fois de suite : le
      // lecteur garde en cache ce qu'il a chargé PAR CHEMIN, et réécrire le
      // fichier qu'il vient de lire lui fait rejouer l'ancien contenu — ou
      // rien. Quatre plutôt que deux depuis qu'une synthèse peut tourner
      // pendant une lecture : à un instant donné, deux fichiers sont vivants.
      _slot = (_slot + 1) % 4;
      final wavFile = File('${tmp.path}/speech_out_$_slot.wav');
      await wavFile.writeAsBytes(wav);
      return wavFile.path;
    }
  }

  /// Play a WAV already on disk. Returns when playback *starts*.
  Future<void> playFile(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
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
// nothing blocks the UI. Only the finished WAV bytes cross back.

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
          // Le WAV est encodé ICI, pas côté principal : la conversion boucle
          // sur chaque échantillon, et pour quelques secondes de parole ça
          // faisait des dizaines de milliers de tours sur le fil de l'UI, à
          // chaque phrase, pendant un appel. Le worker a déjà fait le gros du
          // travail, autant lui laisser celui-là.
          toMain.send([
            'audio',
            NeuralTtsEngine._float32ToWav(audio.samples, audio.sampleRate),
          ]);
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
    // Ce que la machine peut donner, moins un cœur laissé au reste — l'appel
    // WebRTC, la reconnaissance et l'interface tournent en même temps. Plafonné
    // à 4 : au-delà, la synthèse ne gagne plus grand-chose et commence à
    // disputer ses cœurs à l'appel lui-même. 2 en dur laissait la moitié de
    // l'appareil inutilisée pendant que la synthèse traînait.
    numThreads: _inferenceThreads,
    debug: false,
    provider: 'cpu',
  );
}

/// Combien de cœurs la synthèse a le droit d'utiliser.
int get _inferenceThreads {
  final n = Platform.numberOfProcessors - 1;
  return n < 2 ? 2 : (n > 4 ? 4 : n);
}
