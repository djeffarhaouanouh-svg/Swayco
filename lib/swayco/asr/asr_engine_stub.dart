import 'package:flutter/foundation.dart';

import 'asr_catalogue.dart';

/// Web stub — ONNX Runtime and libvosk both need dart:ffi. [AsrService] guards
/// every call with `if (kIsWeb)`, so these are never invoked at runtime.
class SttChunk {
  const SttChunk({this.partial = '', this.finalText = ''});
  static const empty = SttChunk();
  final String partial;
  final String finalText;
  bool get hasFinal => finalText.trim().isNotEmpty;
}

abstract class AsrEngine {
  Future<void> load(String modelDir, String lang);
  bool get isReady;
  bool get isStreaming => false;
  Future<SttChunk> acceptFrame(Float32List samples16k) async => SttChunk.empty;
  Future<String> flush() async => '';
  Future<void> reset() async {}
  Future<String> transcribe(Float32List samples16k);
  Future<void> dispose();
}

AsrEngine createAsrEngine(AsrEngineKind kind) =>
    throw UnsupportedError('On-device STT is unavailable on web');
