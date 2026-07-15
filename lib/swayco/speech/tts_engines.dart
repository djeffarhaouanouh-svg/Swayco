/// Web-safe front door to the on-device TTS engines.
///
/// Both engines bind the runtime through `dart:ffi`, which does not exist on the
/// web — importing them directly from [SpeechService] broke the web build even
/// though every call site is already `kIsWeb`-guarded (an import is resolved at
/// compile time, a runtime guard comes too late). Same pattern as
/// `asr/asr_engine.dart`.
export 'tts_engines_stub.dart' if (dart.library.ffi) 'tts_engines_native.dart';
