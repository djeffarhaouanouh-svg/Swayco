import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_engine_native.dart';

/// The neural ASR on sherpa-onnx's `OfflineRecognizer`, Moonshine **v2**
/// (2-file: encoder + merged decoder + tokens.txt).
///
/// Replaces the hand-rolled ONNX Runtime pipeline (encoder/decoder sessions,
/// manual greedy loop, argmax, tensor flattening, per-export attention_mask
/// handling): sherpa does all of that natively, so this engine shrank to a
/// create-stream / accept / decode / read-text loop.
///
/// A clip engine, not a streaming one — the recogniser attends over the whole
/// segment. It inherits [AsrEngine]'s no-op streaming members (hence `extends`)
/// and is driven by the caller's VAD.
class NeuralAsrEngine extends AsrEngine {
  static bool _bindingsReady = false;

  sherpa.OfflineRecognizer? _recognizer;

  /// decode() is a blocking native call; overlapping requests are dropped rather
  /// than queued — a stale utterance decoded late would land after the one that
  /// followed it.
  bool _busy = false;

  @override
  Future<void> load(String modelDir, String lang) async {
    if (!_bindingsReady) {
      sherpa.initBindings();
      _bindingsReady = true;
    }
    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        moonshine: sherpa.OfflineMoonshineModelConfig(
          encoder: '$modelDir/encoder.onnx',
          mergedDecoder: '$modelDir/decoder_merged.onnx',
        ),
        tokens: '$modelDir/tokens.txt',
        numThreads: 1,
        debug: false,
        provider: 'cpu',
        modelType: 'moonshine',
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
      debugPrint('[neural-asr] transcribe error: $e');
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
