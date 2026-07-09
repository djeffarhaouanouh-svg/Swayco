// Web stub — ONNX Runtime uses dart:ffi which is unavailable on web.
// KokoroService guards every call with `if (kIsWeb) return;` so these
// methods are never actually invoked at runtime.

class TtsPlayer {
  Future<void> loadModel(String modelPath) async {}
  bool get isReady => false;
  Future<void> speak(String text, String langCode, String voicePath) async {}
  Stream<void> get onPlaybackComplete => const Stream<void>.empty();
  Future<void> stop() async {}
  Future<void> dispose() async {}
}
