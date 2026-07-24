import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../services/debug_overlay.dart';
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

  /// Try the phone's neural accelerator before falling back to the CPU.
  ///
  /// The NPU (Neural Engine on iOS, NNAPI on Android) is built for exactly this
  /// and sits completely idle during a call, while the CPU is also carrying
  /// WebRTC and the UI. The win lands mostly on the ENCODER — on a short
  /// utterance it does the bulk of the work, because it attends over the whole
  /// padded segment in one pass; the decoder emits a handful of tokens and may
  /// gain nothing, since per-step accelerator hand-offs can cost more than they
  /// save.
  ///
  /// OFF, and measured — not assumed.
  ///
  /// On device, CoreML decodes SLOWER than the CPU: 0.74 s of audio took
  /// 1121 ms (1.51x real time) where the CPU does ~0.21x, the penalty scaling
  /// inversely with clip length — a ~1 s fixed cost per inference, paid by the
  /// decoder's token-by-token hand-offs. The encoder does gain; the decoder
  /// gives it all back and more.
  ///
  /// It was briefly ON, as a TRADE: accept the slower decode to hand a free CPU
  /// to on-device voice conversion, which ran there alongside WebRTC and the UI.
  /// With the converter gone, only the slow half of that trade is left, so the
  /// accelerator is pure loss — ~6x the decode time for nothing. Turn this back
  /// on only together with something CPU-hungry that needs the room.
  static const bool _tryAccelerator = false;

  /// Ordered backends to attempt. Always ends on 'cpu': a build without the
  /// provider compiled in, or a device without the hardware, must NOT take the
  /// STT — and therefore the whole call — down with it.
  static List<String> get _providers {
    if (!_tryAccelerator) return const ['cpu'];
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return const ['coreml', 'cpu'];
      case TargetPlatform.android:
        return const ['nnapi', 'cpu'];
      default:
        return const ['cpu'];
    }
  }

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
    for (final provider in _providers) {
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
          // ONE thread, not two, DURING a call on purpose. The decode is a burst
          // of native CPU that runs while WebRTC's real-time audio thread also
          // needs a core; with two decode threads the 15 Pro's outgoing voice
          // came out warbled/robotic, and it cleared the instant translation was
          // cut on both sides (call brutto = perfect). Confirmed by the user:
          // the call alone is flawless, the two flows together are not. One
          // thread leaves a core for the audio, at the cost of a slower decode —
          // the decode was 0.38x realtime, so it has room. If the warble
          // survives this, the cause is the second capture itself, not the CPU.
          numThreads: 1,
          debug: false,
          provider: provider,
          modelType: 'whisper',
        ),
      );
      try {
        _recognizer = sherpa.OfflineRecognizer(config);
        // Logged so the on-screen panel says which backend actually took it.
        // The runtime can also fall back internally without raising, so this
        // line reports what we ASKED for — compare `stt decode` times to see
        // whether the accelerator really did anything.
        DebugOverlay.log('stt engine provider=$provider');
        return;
      } catch (e) {
        DebugOverlay.log('stt provider=$provider unavailable ($e)');
        _recognizer = null;
      }
    }
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
