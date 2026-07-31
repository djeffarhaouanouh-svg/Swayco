import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'ja_reading_ffi.dart';
import 'ja_phonemizer.dart';
import 'ja_tokens.dart';
import 'tts_audio_context.dart';

/// On-device **Japanese** TTS engine (see `docs/ja_tts_engine_plan.md`).
///
/// Japanese can't go through sherpa's text frontend (it char-splits kanji), so
/// this engine does its own g2p and feeds the model pre-computed tokens:
///   native the reading frontend reading ([JaReadingFrontend]) → katakana
///   → [expandChoonpu] + [phonemizeKatakana] → token/tone ids
///   → patched sherpa `GenerateFromTokens` ([generateFromTokens]) → PCM.
/// The model still runs on the runtime's **single** ONNX Runtime — no second runtime.
///
/// Mirrors [NeuralTtsEngine]: everything native lives in a worker isolate (model
/// load + generate are blocking calls); only text in and PCM out cross the
/// boundary. Public surface matches so `SpeechService` can treat it like the
/// sherpa engine.
///
/// NOTE: requires the app to link the patched sherpa framework (M4) — the
/// `SherpaOnnxOfflineTtsGenerateFromTokens` symbol is absent from the stock one.
class JaTtsModel {
  const JaTtsModel({
    required this.model,
    required this.tokens,
    required this.lexicon,
    required this.dictDir,
  });

  /// fp16 ja `.onnx`, its `tokens.txt`, a `lexicon.txt` (only to satisfy sherpa
  /// engine creation — g2p is bypassed), and the extracted the reading frontend dict dir.
  final String model;
  final String tokens;
  final String lexicon;
  final String dictDir;

  Map<String, dynamic> toMap() => {
        'model': model,
        'tokens': tokens,
        'lexicon': lexicon,
        'dictDir': dictDir,
      };

  static JaTtsModel fromMap(Map<String, dynamic> m) => JaTtsModel(
        model: m['model'] as String,
        tokens: m['tokens'] as String,
        lexicon: m['lexicon'] as String,
        dictDir: m['dictDir'] as String,
      );
}

class JaTtsEngine {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<List<dynamic>>? _pending;

  final AudioPlayer _player = AudioPlayer();
  bool _configured = false;
  /// Le nom de fichier courant, tourné à chaque phrase.
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
    _isolate = await Isolate.spawn(_jaTtsWorkerMain, rp.sendPort);
    _toWorker = await handshake.future;
  }

  Future<void> configure(JaTtsModel m) async {
    await _ensureSpawned();
    final c = Completer<List<dynamic>>();
    _pending = c;
    _toWorker!.send(['configure', m.toMap()]);
    final res = await c.future;
    if (res.isEmpty || res[0] != 'configured') {
      _configured = false;
      throw StateError(
          'ja TTS configure failed: ${res.length > 1 ? res[1] : "?"}');
    }
    // Route playback like flutter_tts (the call's voice route), not the media
    // route a bare AudioPlayer would use.
    await applyCallTtsAudioContext(_player);
    _configured = true;
  }

  bool get isReady => _configured;

  /// Synthétise et lit. Gardé d'un bloc pour les appelants qui veulent juste
  /// une voix ; en appel, les deux moitiés sont pilotées séparément.
  Future<void> speak(String text, {int sid = 0, double speed = 1.0}) async {
    final path = await synthesiseToFile(text, sid: sid, speed: speed);
    if (path == null) return;
    await playFile(path);
  }

  /// Synthétise vers un WAV sur disque et rend son chemin — rien n'est lu. Les
  /// appels se mettent à la queue leu leu au lieu d'être abandonnés : le worker
  /// n'a qu'un moteur, mais une phrase perdue en silence est pire qu'une
  /// phrase qui attend son tour.
  Future<String?> synthesiseToFile(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) {
    if (!_configured) throw StateError('ja TTS not configured');
    if (text.trim().isEmpty) return Future<String?>.value();
    final job = _synthQueue.then((_) => _synthesiseOne(text, sid, speed));
    _synthQueue = job.then((_) {}, onError: (_) {});
    return job;
  }

  Future<String?> _synthesiseOne(String text, int sid, double speed) async {
    final c = Completer<List<dynamic>>();
    _pending = c;
    _toWorker!.send(['speak', text, sid, speed]);
    final res = await c.future;
    if (res.isEmpty || res[0] != 'audio') return null;
    final wav = res[1] as Uint8List;
    if (wav.isEmpty) return null;

    final tmp = await getTemporaryDirectory();
    await tmp.create(recursive: true);
    // Un nom qui tourne sur quatre, jamais le même deux fois de suite : le
    // lecteur garde en cache ce qu'il a chargé PAR CHEMIN.
    _slot = (_slot + 1) % 4;
    final wavFile = File('${tmp.path}/ja_speech_out_$_slot.wav');
    await wavFile.writeAsBytes(wav);
    return wavFile.path;
  }

  /// Lit un WAV déjà sur disque. Rend la main au DÉMARRAGE de la lecture.
  Future<void> playFile(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

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

  static Uint8List _float32ToWav(Float32List samples, int sampleRate) {
    final numSamples = samples.length;
    final data = ByteData(44 + numSamples * 2);
    var o = 0;
    void setUint8(int v) => data.setUint8(o++, v);
    void setU16(int v) {
      data.setUint16(o, v, Endian.little);
      o += 2;
    }

    void setU32(int v) {
      data.setUint32(o, v, Endian.little);
      o += 4;
    }

    setUint8(0x52); setUint8(0x49); setUint8(0x46); setUint8(0x46); // RIFF
    setU32(36 + numSamples * 2);
    setUint8(0x57); setUint8(0x41); setUint8(0x56); setUint8(0x45); // WAVE
    setUint8(0x66); setUint8(0x6D); setUint8(0x74); setUint8(0x20); // fmt
    setU32(16);
    setU16(1); // PCM
    setU16(1); // mono
    setU32(sampleRate);
    setU32(sampleRate * 2);
    setU16(2);
    setU16(16);
    setUint8(0x64); setUint8(0x61); setUint8(0x74); setUint8(0x61); // data
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
// Owns the runtime (for its ORT + model) and the the reading frontend frontend.
// FFI bindings are per-isolate, so initBindings + JaReadingFrontend.load run here.

void _jaTtsWorkerMain(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);

  var bindingsReady = false;
  sherpa.OfflineTts? tts;
  JaReadingFrontend? frontend;
  Map<String, int> tokenMap = const {};

  rp.listen((message) {
    final msg = message as List<dynamic>;
    switch (msg[0] as String) {
      case 'configure':
        try {
          if (!bindingsReady) {
            sherpa.initBindings();
            bindingsReady = true;
          }
          final m = JaTtsModel.fromMap((msg[1] as Map).cast<String, dynamic>());
          tts?.free();
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                vits: sherpa.OfflineTtsVitsModelConfig(
                  model: m.model,
                  tokens: m.tokens,
                  lexicon: m.lexicon,
                  noiseScale: 0.6,
                  noiseScaleW: 0.8,
                  lengthScale: 1.0,
                ),
                // Ce que la machine peut donner, moins un cœur laissé au
                // reste (appel WebRTC, reconnaissance, interface).
                numThreads: _inferenceThreads,
                debug: false,
                provider: 'cpu',
              ),
              // maxNumSenetences defaults to 1 (note: the package spells it so).
            ),
          );
          frontend?.dispose();
          frontend = JaReadingFrontend.load(m.dictDir);
          tokenMap = parseTokens(File(m.tokens).readAsStringSync());
          toMain.send(['configured']);
        } catch (e) {
          tts = null;
          frontend = null;
          toMain.send(['error', e.toString()]);
        }
        break;
      case 'speak':
        try {
          final engine = tts;
          final oj = frontend;
          if (engine == null || oj == null) {
            toMain.send(['error', 'not configured']);
            break;
          }
          final text = msg[1] as String;
          final sid = msg[2] as int;
          final speed = msg[3] as double;

          final reading = expandChoonpu(oj.kana(text));
          final ph = phonemizeKatakana(reading, tokenMap);
          final pcm = generateFromTokens(
            engine.ptr,
            ph.tokenIds,
            ph.toneIds,
            sid: sid,
            speed: speed,
          );
          // Le WAV est encodé ICI : la conversion boucle sur chaque
          // échantillon, et sur le fil de l'UI ça se voyait à chaque phrase.
          toMain.send([
            'audio',
            JaTtsEngine._float32ToWav(pcm.samples, pcm.sampleRate),
          ]);
        } catch (e) {
          toMain.send(['error', e.toString()]);
        }
        break;
      case 'dispose':
        tts?.free();
        tts = null;
        frontend?.dispose();
        frontend = null;
        rp.close();
        break;
    }
  });
}

/// Combien de cœurs la synthèse a le droit d'utiliser.
int get _inferenceThreads {
  final n = Platform.numberOfProcessors - 1;
  return n < 2 ? 2 : (n > 4 ? 4 : n);
}
