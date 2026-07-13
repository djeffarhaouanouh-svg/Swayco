import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_catalogue.dart';
import 'asr_engine_native.dart';

/// The universal fallback engine: one int8 model covering 99 languages, used
/// for every language with no dedicated per-language model (see
/// [asr_catalogue]).
///
/// A clip engine like [NeuralAsrEngine]: it attends over a whole VAD segment,
/// inherits [AsrEngine]'s no-op streaming members, and drops overlapping
/// requests rather than queueing them.
///
/// It decodes autoregressively, so it is the slowest engine here — two knobs
/// keep it inside a live call:
///
/// * **`tailPaddings`** is the one that matters. The runtime pads every segment
///   before encoding, and its default (1000 frames = 10 s) is set for offline
///   transcription: a 4 s utterance would cost 14 s of encoder. [_tailPaddings]
///   cuts that to 3 s, which is all the decoder needs to not clip the last word.
/// * **`language`** is passed explicitly, so no language-ID pass runs first.
class UniversalAsrEngine extends AsrEngine {
  static bool _bindingsReady = false;

  /// Frames of silence appended before encoding (10 ms each) — see the class
  /// doc. Enough to keep the last word, far below the runtime's offline default.
  static const int _tailPaddings = 300;

  sherpa.OfflineRecognizer? _recognizer;
  bool _busy = false;

  @override
  Future<void> load(String modelDir, String lang) async {
    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }
    // The `whisper` field and `modelType` below name the upstream architecture
    // the ONNX graphs were exported in: sherpa dispatches on them, so they are
    // the runtime's vocabulary, not ours. They are the only place the family
    // name appears — the rest of the app calls this the universal engine.
    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: '$modelDir/${UniversalAsrSpec.encoderFile}',
          decoder: '$modelDir/${UniversalAsrSpec.decoderFile}',
          language: universalLangCode(lang),
          task: 'transcribe',
          tailPaddings: _tailPaddings,
        ),
        tokens: '$modelDir/${UniversalAsrSpec.tokensFile}',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
        modelType: 'whisper',
      ),
    );
    _recognizer = sherpa.OfflineRecognizer(config);
  }

  @override
  bool get isReady => _recognizer != null;

  @override
  Future<String> transcribe(Float32List samples16k) async {
    final rec = _recognizer;
    if (rec == null) return '';
    if (_busy || samples16k.isEmpty) return '';
    _busy = true;

    sherpa.OfflineStream? stream;
    try {
      stream = rec.createStream();
      stream.acceptWaveform(samples: samples16k, sampleRate: 16000);
      rec.decode(stream);
      return rec.getResult(stream).text.trim();
    } catch (e) {
      debugPrint('[universal-asr] transcribe error: $e');
      return '';
    } finally {
      stream?.free();
      _busy = false;
    }
  }

  @override
  Future<void> dispose() async {
    _recognizer?.free();
    _recognizer = null;
  }
}
