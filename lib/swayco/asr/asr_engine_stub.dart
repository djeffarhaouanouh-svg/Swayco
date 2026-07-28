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

class AsrResult {
  const AsrResult({
    required this.text,
    this.alternatives = const [],
    this.lowConfidence = const [],
  });
  static const empty = AsrResult(text: '');
  final String text;
  final List<String> alternatives;
  final List<String> lowConfidence;
  bool get hasDoubt => alternatives.isNotEmpty || lowConfidence.isNotEmpty;
  AsrResult copyWith({String? text}) => AsrResult(
        text: text ?? this.text,
        alternatives: alternatives,
        lowConfidence: lowConfidence,
      );
}

abstract class AsrEngine {
  Future<void> load(String modelDir, String lang);
  bool get isReady;
  bool get isStreaming => false;
  Future<SttChunk> acceptFrame(Float32List samples16k) async => SttChunk.empty;
  Future<String> flush() async => '';
  Future<void> reset() async {}
  Future<String> transcribe(Float32List samples16k);
  Future<AsrResult> transcribeDetailed(Float32List samples16k) async =>
      AsrResult(text: await transcribe(samples16k));
  Future<void> dispose();
}

AsrEngine createAsrEngine(AsrEngineKind kind) =>
    throw UnsupportedError('On-device STT is unavailable on web');
