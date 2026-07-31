/// Web: on-device TTS does not exist (the runtime is `dart:ffi`). The browser
/// speaks with the Web Speech API instead — see `call_screen._speakDeviceTts`.
///
/// These stubs exist only so [SpeechService] compiles for the web. Every one of
/// its methods already returns early on `kIsWeb`, so nothing here is ever
/// reached; they must simply match the native API shape.
class NeuralTtsModel {
  const NeuralTtsModel({
    required this.model,
    required this.tokens,
    required this.dataDir,
  });
  final String model;
  final String tokens;
  final String dataDir;
}

class JaTtsModel {
  const JaTtsModel({
    required this.model,
    required this.tokens,
    required this.lexicon,
    required this.dictDir,
  });
  final String model;
  final String tokens;
  final String lexicon;
  final String dictDir;
}

class NeuralTtsEngine {
  bool get isReady => false;
  Stream<void> get onPlaybackComplete => const Stream<void>.empty();
  Future<void> configure(NeuralTtsModel m) async {}
  Future<void> speak(String text, {int sid = 0, double speed = 1.0}) async {}
  Future<String?> synthesiseToFile(String text,
          {int sid = 0, double speed = 1.0}) async =>
      null;
  Future<void> playFile(String path) async {}
  Future<void> stop() async {}
  Future<void> dispose() async {}
}

class JaTtsEngine {
  bool get isReady => false;
  Stream<void> get onPlaybackComplete => const Stream<void>.empty();
  Future<void> configure(JaTtsModel m) async {}
  Future<void> speak(String text, {int sid = 0, double speed = 1.0}) async {}
  Future<String?> synthesiseToFile(String text,
          {int sid = 0, double speed = 1.0}) async =>
      null;
  Future<void> playFile(String path) async {}
  Future<void> stop() async {}
  Future<void> dispose() async {}
}
