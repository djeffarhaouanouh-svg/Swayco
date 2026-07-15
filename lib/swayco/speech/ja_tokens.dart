/// FFI to the patched sherpa symbol `SherpaOnnxOfflineTtsGenerateFromTokens`
/// (see `native/sherpa_ja_patch/`). Runs the ja neural model on the runtime's single
/// ONNX Runtime from pre-computed token/tone ids — the piece stock sherpa lacks.
///
/// We reuse the `sherpa_onnx` Dart package to CREATE the `OfflineTts` (it does
/// all the config/model-loading marshalling and owns the ORT session) and only
/// FFI the new generate symbol on its native `ptr`. Requires the app to link the
/// patched sherpa framework (M4); with the stock framework the lookup throws.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
// Internal bindings give the opaque `SherpaOnnxOfflineTts` and the
// `SherpaOnnxGeneratedAudio` struct that `OfflineTts.ptr` and the C API use.
// ignore: implementation_imports
import 'package:sherpa_onnx/src/sherpa_onnx_bindings.dart';

typedef _GenFromTokensNative = Pointer<SherpaOnnxGeneratedAudio> Function(
    Pointer<SherpaOnnxOfflineTts>, Pointer<Int64>, Int32, Pointer<Int64>, Int32,
    Int32, Float);
typedef _GenFromTokens = Pointer<SherpaOnnxGeneratedAudio> Function(
    Pointer<SherpaOnnxOfflineTts>, Pointer<Int64>, int, Pointer<Int64>, int, int,
    double);
typedef _DestroyAudioNative = Void Function(
    Pointer<SherpaOnnxGeneratedAudio>);
typedef _DestroyAudio = void Function(Pointer<SherpaOnnxGeneratedAudio>);

class _Syms {
  _Syms(this.gen, this.destroy);
  final _GenFromTokens gen;
  final _DestroyAudio destroy;

  static _Syms? _cached;
  static _Syms get instance {
    final c = _cached;
    if (c != null) return c;
    final lib = DynamicLibrary.process();
    final s = _Syms(
      lib.lookupFunction<_GenFromTokensNative, _GenFromTokens>(
          'SherpaOnnxOfflineTtsGenerateFromTokens'),
      lib.lookupFunction<_DestroyAudioNative, _DestroyAudio>(
          'SherpaOnnxDestroyOfflineTtsGeneratedAudio'),
    );
    return _cached = s;
  }
}

/// Result of a token-level synth: mono float32 PCM in [-1, 1] plus its rate.
class JaPcm {
  const JaPcm(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;
}

/// Synthesise from [tokenIds]/[toneIds] (final, blank-interleaved ids from the
/// phonemizer) using the sherpa engine whose native pointer is [ttsPtr]
/// (`OfflineTts.ptr`). Returns empty PCM if the model produced nothing.
JaPcm generateFromTokens(
  Pointer<SherpaOnnxOfflineTts> ttsPtr,
  List<int> tokenIds,
  List<int> toneIds, {
  int sid = 0,
  double speed = 1.0,
}) {
  final syms = _Syms.instance;
  final n = tokenIds.length;
  final tokPtr = malloc<Int64>(n);
  final tonePtr = toneIds.isEmpty ? nullptr : malloc<Int64>(toneIds.length);
  try {
    final tokList = tokPtr.asTypedList(n);
    for (var i = 0; i < n; i++) {
      tokList[i] = tokenIds[i];
    }
    if (toneIds.isNotEmpty) {
      final toneList = tonePtr.asTypedList(toneIds.length);
      for (var i = 0; i < toneIds.length; i++) {
        toneList[i] = toneIds[i];
      }
    }
    final audioPtr = syms.gen(
        ttsPtr, tokPtr, n, tonePtr, toneIds.length, sid, speed);
    if (audioPtr == nullptr) return JaPcm(Float32List(0), 0);
    try {
      final audio = audioPtr.ref;
      final count = audio.n;
      final out = Float32List(count);
      final src = audio.samples.asTypedList(count);
      out.setAll(0, src);
      return JaPcm(out, audio.sampleRate);
    } finally {
      syms.destroy(audioPtr);
    }
  } finally {
    malloc.free(tokPtr);
    if (tonePtr != nullptr) malloc.free(tonePtr);
  }
}
