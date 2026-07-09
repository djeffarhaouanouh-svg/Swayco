import 'dart:typed_data';

import 'moonshine_engine.dart';
import 'stt_catalogue.dart';
import 'vosk_engine.dart';

/// One step of a streaming engine's output.
///
/// [partial] is the running hypothesis for the utterance in progress. It is
/// *revised*, not appended to — replace what you displayed, never accumulate.
/// [finalText] is non-empty exactly on the frame where the engine's own
/// endpointer closed an utterance; that is the text worth translating.
class SttChunk {
  const SttChunk({this.partial = '', this.finalText = ''});
  static const empty = SttChunk();

  final String partial;
  final String finalText;

  bool get hasFinal => finalText.trim().isNotEmpty;
}

/// One on-device recogniser, already pointed at a downloaded model.
///
/// Two shapes, distinguished by [isStreaming]:
///
///  * **Streaming** (Vosk/Kaldi): feed [acceptFrame] every frame. The engine
///    endpoints utterances itself and emits partial hypotheses meanwhile.
///  * **Clip** (Moonshine): feed [transcribe] one complete utterance. Its
///    encoder attends over the whole segment, so it cannot consume a stream.
///
/// Both do real work synchronously on the calling isolate.
abstract class SttEngine {
  /// [modelDir] is the extracted model directory; [lang] the BCP-47 primary tag.
  Future<void> load(String modelDir, String lang);

  bool get isReady;

  bool get isStreaming => false;

  /// Feed one frame of a continuous stream. 16 kHz mono, samples in [-1, 1].
  /// Only meaningful when [isStreaming].
  Future<SttChunk> acceptFrame(Float32List samples16k) async => SttChunk.empty;

  /// Close the utterance in progress, return whatever was decoded, and reset.
  /// Call when the mic goes away (doze, hang-up) so a half-decoded phrase is
  /// not spliced onto the next one. Only meaningful when [isStreaming].
  Future<String> flush() async => '';

  /// Drop decoder state without returning a result — for audio we deliberately
  /// discarded (mute, our own TTS echo) which must not contaminate the next
  /// utterance. Only meaningful when [isStreaming].
  Future<void> reset() async {}

  /// Transcribe one complete, VAD-clipped utterance. 16 kHz mono, [-1, 1].
  /// Returns '' when nothing was recognised. Only meaningful when ![isStreaming].
  Future<String> transcribe(Float32List samples16k);

  Future<void> dispose();
}

SttEngine createSttEngine(SttEngineKind kind) => switch (kind) {
      SttEngineKind.moonshine => MoonshineEngine(),
      SttEngineKind.vosk => VoskEngine(),
    };
