// Conditional export, mirroring swayco/speech/tts_player.dart:
//   native (dart:ffi) → sherpa-onnx OfflineRecognizer (universal Whisper)
//   web              → no-op stub (STT is native-only; web keeps the cloud engine path)
export 'asr_engine_stub.dart' if (dart.library.ffi) 'asr_engine_native.dart';
