import 'dart:typed_data';

import 'moonshine_engine.dart';
import 'stt_catalogue.dart';
import 'vosk_engine.dart';

/// One on-device recogniser, already pointed at a downloaded model.
///
/// Implementations are synchronous-blocking inside [transcribe] (ONNX Runtime
/// and Kaldi both do real work on the calling thread), so callers should feed
/// them VAD-clipped utterances rather than a continuous stream.
abstract class SttEngine {
  /// [modelDir] is the extracted model directory; [lang] the BCP-47 primary tag.
  Future<void> load(String modelDir, String lang);

  bool get isReady;

  /// 16 kHz mono, samples in [-1, 1]. Returns '' when nothing was recognised.
  Future<String> transcribe(Float32List samples16k);

  Future<void> dispose();
}

SttEngine createSttEngine(SttEngineKind kind) => switch (kind) {
      SttEngineKind.moonshine => MoonshineEngine(),
      SttEngineKind.vosk => VoskEngine(),
    };
