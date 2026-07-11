import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'ja_openjtalk_ffi.dart';
import 'ja_phonemizer.dart';
import 'ja_sherpa_tokens.dart';

/// On-device **Japanese** TTS engine (see `docs/ja_tts_engine_plan.md`).
///
/// Japanese can't go through sherpa's text frontend (it char-splits kanji), so
/// this engine does its own g2p and feeds the model pre-computed tokens:
///   native OpenJTalk reading ([JaOpenJTalk]) → katakana
///   → [expandChoonpu] + [phonemizeKatakana] → token/tone ids
///   → patched sherpa `GenerateFromTokens` ([generateFromTokens]) → PCM.
/// The model still runs on sherpa's **single** ONNX Runtime — no second runtime.
///
/// Mirrors [SherpaTtsEngine]: everything native lives in a worker isolate (model
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
  /// engine creation — g2p is bypassed), and the extracted OpenJTalk dict dir.
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
    _configured = true;
  }

  bool get isReady => _configured;

  Future<void> speak(String text, {int sid = 0, double speed = 1.0}) async {
    if (!_configured) throw StateError('ja TTS not configured');
    if (_inferring) return;
    if (text.trim().isEmpty) return;
    _inferring = true;
    try {
      final c = Completer<List<dynamic>>();
      _pending = c;
      _toWorker!.send(['speak', text, sid, speed]);
      final res = await c.future;
      if (res.isEmpty || res[0] != 'audio') return;
      final samples = res[1] as Float32List;
      final sampleRate = res[2] as int;
      if (samples.isEmpty) return;

      final wav = _float32ToWav(samples, sampleRate);
      final tmp = await getTemporaryDirectory();
      final wavFile = File('${tmp.path}/ja_speech_out.wav');
      await wavFile.writeAsBytes(wav);

      await _player.stop();
      await _player.play(DeviceFileSource(wavFile.path));
    } finally {
      _inferring = false;
    }
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
// Owns the sherpa OfflineTts (for its ORT + model) and the OpenJTalk frontend.
// FFI bindings are per-isolate, so initBindings + JaOpenJTalk.load run here.

void _jaTtsWorkerMain(SendPort toMain) {
  final rp = ReceivePort();
  toMain.send(rp.sendPort);

  var bindingsReady = false;
  sherpa.OfflineTts? tts;
  JaOpenJTalk? frontend;
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
                numThreads: 2,
                debug: false,
                provider: 'cpu',
              ),
              // maxNumSenetences defaults to 1 (note: the package spells it so).
            ),
          );
          frontend?.dispose();
          frontend = JaOpenJTalk.load(m.dictDir);
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
          toMain.send(['audio', pcm.samples, pcm.sampleRate]);
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
