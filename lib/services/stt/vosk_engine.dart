import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'stt_engine_native.dart';

// ── libvosk C ABI ────────────────────────────────────────────────────────────
// A direct dart:ffi binding rather than a plugin: `vosk_flutter` last shipped in
// 2023 and declares no iOS support, and we need both platforms.

typedef _ModelNewC = Pointer<Void> Function(Pointer<Utf8>);
typedef _ModelNew = Pointer<Void> Function(Pointer<Utf8>);
typedef _ModelFreeC = Void Function(Pointer<Void>);
typedef _ModelFree = void Function(Pointer<Void>);

typedef _RecNewC = Pointer<Void> Function(Pointer<Void>, Float);
typedef _RecNew = Pointer<Void> Function(Pointer<Void>, double);

/// Returns 1 when the endpointer closed an utterance (read `vosk_recognizer_result`),
/// 0 while decoding continues, -1 on error. This return value is what lets us
/// drop our own VAD-based segmentation: Kaldi decides where phrases end.
typedef _RecAcceptFC = Int32 Function(Pointer<Void>, Pointer<Float>, Int32);
typedef _RecAcceptF = int Function(Pointer<Void>, Pointer<Float>, int);

typedef _RecResultC = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecResult = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecPartialC = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecPartial = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecFinalC = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecFinal = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecResetC = Void Function(Pointer<Void>);
typedef _RecReset = void Function(Pointer<Void>);
typedef _RecFreeC = Void Function(Pointer<Void>);
typedef _RecFree = void Function(Pointer<Void>);
typedef _SetLogLevelC = Void Function(Int32);
typedef _SetLogLevel = void Function(int);

class _VoskLib {
  _VoskLib(DynamicLibrary lib)
      : modelNew = lib.lookupFunction<_ModelNewC, _ModelNew>('vosk_model_new'),
        modelFree =
            lib.lookupFunction<_ModelFreeC, _ModelFree>('vosk_model_free'),
        recNew = lib.lookupFunction<_RecNewC, _RecNew>('vosk_recognizer_new'),
        recAcceptF = lib.lookupFunction<_RecAcceptFC, _RecAcceptF>(
            'vosk_recognizer_accept_waveform_f'),
        recResult =
            lib.lookupFunction<_RecResultC, _RecResult>('vosk_recognizer_result'),
        recPartial = lib.lookupFunction<_RecPartialC, _RecPartial>(
            'vosk_recognizer_partial_result'),
        recFinal = lib.lookupFunction<_RecFinalC, _RecFinal>(
            'vosk_recognizer_final_result'),
        recReset =
            lib.lookupFunction<_RecResetC, _RecReset>('vosk_recognizer_reset'),
        recFree =
            lib.lookupFunction<_RecFreeC, _RecFree>('vosk_recognizer_free'),
        setLogLevel = lib.lookupFunction<_SetLogLevelC, _SetLogLevel>(
            'vosk_set_log_level');

  final _ModelNew modelNew;
  final _ModelFree modelFree;
  final _RecNew recNew;
  final _RecAcceptF recAcceptF;
  final _RecResult recResult;
  final _RecPartial recPartial;
  final _RecFinal recFinal;
  final _RecReset recReset;
  final _RecFree recFree;
  final _SetLogLevel setLogLevel;

  /// Android links libvosk.so from `jniLibs`; on iOS the static library is
  /// linked into the app binary, so its symbols live in the process itself.
  static _VoskLib open() => _VoskLib(
        Platform.isAndroid
            ? DynamicLibrary.open('libvosk.so')
            : DynamicLibrary.process(),
      );
}

/// Vosk (Kaldi) streaming ASR for the languages Moonshine does not cover: fr,
/// ru, es, it, pt, de, nl. Small models, ~30–48 MB each, one per language.
///
/// Streaming: one recognizer lives for the whole call and is fed every frame.
/// Kaldi's own endpointer says where utterances end, so the caller does not
/// segment. Partial hypotheses come back on every frame in between.
class VoskEngine implements SttEngine {
  static const int _sampleRate = 16000;

  _VoskLib? _lib;
  Pointer<Void>? _model;
  Pointer<Void>? _rec;

  /// A single reusable native buffer. Frames arrive at a steady size, so we
  /// grow once and then never allocate on the audio path again.
  Pointer<Float>? _buf;
  int _bufLen = 0;

  /// accept_waveform is a synchronous Kaldi decode. Overlapping calls would
  /// corrupt recognizer state, so drop a frame rather than reenter.
  bool _busy = false;

  @override
  Future<void> load(String modelDir, String lang) async {
    final lib = _VoskLib.open();
    lib.setLogLevel(-1); // Kaldi is extremely chatty on stdout otherwise.
    final path = modelDir.toNativeUtf8();
    try {
      final model = lib.modelNew(path);
      if (model == nullptr) {
        throw StateError('vosk_model_new failed for $modelDir');
      }
      final rec = lib.recNew(model, _sampleRate.toDouble());
      if (rec == nullptr) {
        lib.modelFree(model);
        throw StateError('vosk_recognizer_new failed');
      }
      _model = model;
      _rec = rec;
      _lib = lib;
    } finally {
      calloc.free(path);
    }
  }

  @override
  bool get isReady => _model != null && _rec != null && _lib != null;

  @override
  bool get isStreaming => true;

  @override
  Future<SttChunk> acceptFrame(Float32List samples16k) async {
    final lib = _lib;
    final rec = _rec;
    if (lib == null || rec == null || samples16k.isEmpty) return SttChunk.empty;
    if (_busy) return SttChunk.empty;
    _busy = true;
    try {
      final buf = _ensureBuf(samples16k.length);
      // Vosk's float API expects samples in [-32768, 32767], not [-1, 1].
      for (var i = 0; i < samples16k.length; i++) {
        buf[i] = samples16k[i] * 32768.0;
      }

      final ended = lib.recAcceptF(rec, buf, samples16k.length);
      if (ended < 0) {
        debugPrint('[vosk] accept_waveform error');
        return SttChunk.empty;
      }
      if (ended == 1) {
        // Endpoint: an utterance closed. `result` consumes it and the
        // recognizer continues cleanly into the next one — no reset needed.
        return SttChunk(finalText: _text(lib.recResult(rec), 'text'));
      }
      return SttChunk(partial: _text(lib.recPartial(rec), 'partial'));
    } catch (e) {
      debugPrint('[vosk] acceptFrame error: $e');
      return SttChunk.empty;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<String> flush() async {
    final lib = _lib;
    final rec = _rec;
    if (lib == null || rec == null) return '';
    try {
      // final_result already resets the recognizer internally.
      return _text(lib.recFinal(rec), 'text');
    } catch (e) {
      debugPrint('[vosk] flush error: $e');
      return '';
    }
  }

  @override
  Future<void> reset() async {
    final lib = _lib;
    final rec = _rec;
    if (lib == null || rec == null) return;
    try {
      lib.recReset(rec);
    } catch (e) {
      debugPrint('[vosk] reset error: $e');
    }
  }

  /// Not used: this engine streams. Kept so a caller that has a whole clip in
  /// hand (a unit test, a file) can still get a transcript out of it.
  @override
  Future<String> transcribe(Float32List samples16k) async {
    if (samples16k.isEmpty) return '';
    await acceptFrame(samples16k);
    return flush();
  }

  Pointer<Float> _ensureBuf(int n) {
    final buf = _buf;
    if (buf != null && _bufLen >= n) return buf;
    if (buf != null) calloc.free(buf);
    final grown = calloc<Float>(n);
    _buf = grown;
    _bufLen = n;
    return grown;
  }

  /// Vosk returns a JSON string owned by the recognizer — do not free it.
  String _text(Pointer<Utf8> json, String key) {
    if (json == nullptr) return '';
    try {
      final decoded = jsonDecode(json.toDartString());
      if (decoded is Map && decoded[key] is String) {
        return (decoded[key] as String).trim();
      }
    } catch (_) {}
    return '';
  }

  @override
  Future<void> dispose() async {
    final lib = _lib;
    final model = _model;
    final rec = _rec;
    final buf = _buf;
    _model = null;
    _rec = null;
    _lib = null;
    _buf = null;
    _bufLen = 0;
    if (lib != null) {
      if (rec != null) lib.recFree(rec);
      if (model != null) lib.modelFree(model);
    }
    if (buf != null) calloc.free(buf);
  }
}
