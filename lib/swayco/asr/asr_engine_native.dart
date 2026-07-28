import 'dart:typed_data';

import 'neural_asr_engine.dart';
import 'asr_catalogue.dart';
import 'lattice_asr_engine.dart';
import 'universal_asr_engine.dart';

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

/// One decoded utterance, plus everything the recogniser knew about it beyond
/// its single best guess.
///
/// A recogniser does not pick a transcript, it RANKS several and hands over the
/// top one. The rest is normally thrown away — and it is exactly what the repair
/// model needs: told that "cardiologue" was scored against "radiologue" and
/// "cardiologie", it can pick the one the sentence actually supports, instead of
/// repairing a single frozen string with no idea where the doubt was.
///
/// The ONNX engines return [text] alone: their decoder is greedy, so there is no
/// second hypothesis to report and no score to read. Everything downstream must
/// therefore treat an empty [alternatives] as "no information", never as "the
/// recogniser was certain".
class AsrResult {
  const AsrResult({
    required this.text,
    this.alternatives = const [],
    this.lowConfidence = const [],
  });

  static const empty = AsrResult(text: '');

  /// The best transcription — what the pipeline speaks and captions.
  final String text;

  /// Rival transcriptions of the SAME audio, best-first, never including [text].
  final List<String> alternatives;

  /// Words inside [text] the recogniser scored lowest. Empty when the engine
  /// reports no per-word confidence at all, which is not the same as confident.
  final List<String> lowConfidence;

  /// Whether the recogniser gave us anything to be suspicious about.
  bool get hasDoubt => alternatives.isNotEmpty || lowConfidence.isNotEmpty;

  AsrResult copyWith({String? text}) => AsrResult(
        text: text ?? this.text,
        alternatives: alternatives,
        lowConfidence: lowConfidence,
      );
}

/// One on-device recogniser, already pointed at a downloaded model.
///
/// Two shapes, distinguished by [isStreaming]:
///
///  * **Streaming** (lattice): feed [acceptFrame] every frame. The engine
///    endpoints utterances itself and emits partial hypotheses meanwhile.
///  * **Clip** (neural): feed [transcribe] one complete utterance. Its
///    encoder attends over the whole segment, so it cannot consume a stream.
///
/// Both do real work synchronously on the calling isolate.
abstract class AsrEngine {
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

  /// [transcribe], plus the rival hypotheses and shaky words when the engine has
  /// them (see [AsrResult]).
  ///
  /// Defaults to wrapping [transcribe], so an engine that knows nothing beyond
  /// its best guess — every ONNX engine here — needs no code at all, and the
  /// callers can use this one method everywhere.
  Future<AsrResult> transcribeDetailed(Float32List samples16k) async =>
      AsrResult(text: await transcribe(samples16k));

  Future<void> dispose();
}

AsrEngine createAsrEngine(AsrEngineKind kind) => switch (kind) {
      AsrEngineKind.neural => NeuralAsrEngine(),
      AsrEngineKind.lattice => LatticeAsrEngine(),
      AsrEngineKind.universal => UniversalAsrEngine(),
    };
