/// Web-safe front door to the voice-clone service.
///
/// The native implementation reaches the ONNX Runtime through `dart:ffi`, which
/// the web does not have. [CallScreen] imports this from code that also builds
/// for the web, and an import is resolved at compile time — a `kIsWeb` guard at
/// the call site comes far too late. Same arrangement as `tts_engines.dart`.
export 'voice_clone_service_stub.dart'
    if (dart.library.ffi) 'voice_clone_service_native.dart';
