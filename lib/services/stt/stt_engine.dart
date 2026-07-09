// Conditional export, mirroring services/kokoro/tts_player.dart:
//   native (dart:ffi) → ONNX Runtime + libvosk implementations
//   web              → no-op stub (STT is native-only; web keeps the x.ai path)
export 'stt_engine_stub.dart' if (dart.library.ffi) 'stt_engine_native.dart';
