// Conditional export: native (dart:ffi available) → real ONNX implementation.
//                      web (dart:ffi unavailable)  → no-op stub.
export 'tts_player_web.dart' if (dart.library.ffi) 'tts_player_native.dart';
