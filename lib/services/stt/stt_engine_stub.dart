import 'package:flutter/foundation.dart';

import 'stt_catalogue.dart';

/// Web stub — ONNX Runtime and libvosk both need dart:ffi. [SttService] guards
/// every call with `if (kIsWeb)`, so these are never invoked at runtime.
abstract class SttEngine {
  Future<void> load(String modelDir, String lang);
  bool get isReady;
  Future<String> transcribe(Float32List samples16k);
  Future<void> dispose();
}

SttEngine createSttEngine(SttEngineKind kind) =>
    throw UnsupportedError('On-device STT is unavailable on web');
