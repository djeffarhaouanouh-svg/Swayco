import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'stt_engine_native.dart';

// ── libvosk C ABI ────────────────────────────────────────────────────────────
// Five entry points is the whole surface we need, which is why this is a direct
// dart:ffi binding rather than a plugin: `vosk_flutter` last shipped in 2023 and
// declares no iOS support, and we need both platforms.

typedef _ModelNewC = Pointer<Void> Function(Pointer<Utf8>);
typedef _ModelNew = Pointer<Void> Function(Pointer<Utf8>);
typedef _ModelFreeC = Void Function(Pointer<Void>);
typedef _ModelFree = void Function(Pointer<Void>);

typedef _RecNewC = Pointer<Void> Function(Pointer<Void>, Float);
typedef _RecNew = Pointer<Void> Function(Pointer<Void>, double);
typedef _RecAcceptFC = Int32 Function(Pointer<Void>, Pointer<Float>, Int32);
typedef _RecAcceptF = int Function(Pointer<Void>, Pointer<Float>, int);
typedef _RecFinalC = Pointer<Utf8> Function(Pointer<Void>);
typedef _RecFinal = Pointer<Utf8> Function(Pointer<Void>);
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
        recFinal = lib.lookupFunction<_RecFinalC, _RecFinal>(
            'vosk_recognizer_final_result'),
        recFree =
            lib.lookupFunction<_RecFreeC, _RecFree>('vosk_recognizer_free'),
        setLogLevel = lib.lookupFunction<_SetLogLevelC, _SetLogLevel>(
            'vosk_set_log_level');

  final _ModelNew modelNew;
  final _ModelFree modelFree;
  final _RecNew recNew;
  final _RecAcceptF recAcceptF;
  final _RecFinal recFinal;
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

/// Vosk (Kaldi) ASR for the languages Moonshine does not cover: fr, ru, es, it,
/// pt, de, nl. Small models, ~30–48 MB each, one per language.
class VoskEngine implements SttEngine {
  _VoskLib? _lib;
  Pointer<Void>? _model;
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
      _model = model;
      _lib = lib;
    } finally {
      calloc.free(path);
    }
  }

  @override
  bool get isReady => _model != null && _lib != null;

  @override
  Future<String> transcribe(Float32List samples16k) async {
    final lib = _lib;
    final model = _model;
    if (lib == null || model == null || samples16k.isEmpty) return '';
    if (_busy) return '';
    _busy = true;

    Pointer<Void>? rec;
    Pointer<Float>? buf;
    try {
      rec = lib.recNew(model, 16000.0);
      if (rec == nullptr) return '';

      // Vosk's float API expects samples in [-32768, 32767], not [-1, 1].
      buf = calloc<Float>(samples16k.length);
      for (var i = 0; i < samples16k.length; i++) {
        buf[i] = samples16k[i] * 32768.0;
      }
      lib.recAcceptF(rec, buf, samples16k.length);

      final json = lib.recFinal(rec).toDartString();
      final decoded = jsonDecode(json);
      if (decoded is Map && decoded['text'] is String) {
        return (decoded['text'] as String).trim();
      }
      return '';
    } catch (e) {
      debugPrint('[vosk] transcribe error: $e');
      return '';
    } finally {
      if (buf != null) calloc.free(buf);
      if (rec != null && rec != nullptr) lib.recFree(rec);
      _busy = false;
    }
  }

  @override
  Future<void> dispose() async {
    final lib = _lib;
    final model = _model;
    _model = null;
    _lib = null;
    if (lib != null && model != null) lib.modelFree(model);
  }
}
