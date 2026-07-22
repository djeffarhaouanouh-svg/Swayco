/// OpenVoice V2 tone-colour conversion: keep the sentence, swap the timbre.
///
/// This is the second half of "the peer hears YOUR voice" (docs/voice-cloning.md).
/// The TTS stays exactly what it is — a correct, neutral voice in the target
/// language — and this pass moves its timbre onto the speaker's. Splitting the
/// two is what makes the feature affordable: the language problem is already
/// solved by the base model, so all that is left is a single 33 M-parameter
/// pass (RTF 0.20 on Apple silicon, fp32 on the CPU — do not "optimise" it to
/// int8 or CoreML, both are measurably worse).
///
/// Two graphs, run at different rates:
///   * `ref_encoder.onnx` (3 MB) → a 256-float fingerprint of a speaker. ~50 ms,
///     computed from a VAD segment the recogniser is already handling.
///   * `converter_fp32.onnx` (121 MB) → one pass per sentence, fixed 520 frames
///     (≈ 6 s); longer sentences are chunked and overlap-added here.
///
/// It runs on the ONNX Runtime the app already has ([OrtRuntime]) — no second
/// runtime, which is the invariant the whole native stack is built around.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'ort_runtime.dart';
import 'voice_spectrogram.dart';

/// Frames per converter pass — the graph's input is a fixed `[1, 513, 520]`.
const int kConverterFrames = 520;

/// Frames of overlap between consecutive chunks, cross-faded on join. 8 frames
/// is 93 ms, enough to hide the seam without wasting a pass.
const int _kChunkOverlap = 8;

/// Conversion strength. `target' = source + alpha * (target - source)`.
///
/// **This is the knob, not `tau`.** `tau` is the noise amplitude of the
/// posterior sample (and is compiled out of our export anyway); what actually
/// exaggerates the timbre is extrapolating past the target embedding. Chosen by
/// ear: 1.0 is too timid to be recognisable, 2.0+ turns metallic.
const double kDefaultAlpha = 1.5;

/// A speaker's tone colour: 256 floats out of the reference encoder.
///
/// Small enough (1 KB) to send once over the call's data channel, and it is not
/// audio — nothing reconstructible, nothing to store. It sharpens as more of
/// the speaker's voice is heard: [merge] folds a new observation in.
class VoiceFingerprint {
  VoiceFingerprint(this.values, {this.observations = 1})
      : assert(values.length == 256);

  final Float32List values;

  /// How many reference segments this fingerprint averages. More is better —
  /// averaging two references measurably beat one.
  final int observations;

  /// Running average of [this] and [other], weighted by how much each has seen.
  VoiceFingerprint merge(VoiceFingerprint other) {
    final n = observations + other.observations;
    final out = Float32List(256);
    for (var i = 0; i < 256; i++) {
      out[i] = (values[i] * observations + other.values[i] * other.observations) / n;
    }
    return VoiceFingerprint(out, observations: n);
  }

  /// Wire form for the data channel: 256 little-endian float32.
  Uint8List toBytes() {
    final out = ByteData(256 * 4);
    for (var i = 0; i < 256; i++) {
      out.setFloat32(i * 4, values[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static VoiceFingerprint fromBytes(Uint8List bytes, {int observations = 1}) {
    if (bytes.length != 256 * 4) {
      throw ArgumentError('fingerprint must be 1024 bytes, got ${bytes.length}');
    }
    final view = ByteData.sublistView(bytes);
    final values = Float32List(256);
    for (var i = 0; i < 256; i++) {
      values[i] = view.getFloat32(i * 4, Endian.little);
    }
    return VoiceFingerprint(values, observations: observations);
  }

  /// Cosine similarity — same speaker is high, different speakers are not.
  /// Used by the checks, and useful as a sanity gate before adopting a
  /// mid-call refinement that looks like it captured someone else.
  double similarityTo(VoiceFingerprint other) {
    var dot = 0.0, a = 0.0, b = 0.0;
    for (var i = 0; i < 256; i++) {
      dot += values[i] * other.values[i];
      a += values[i] * values[i];
      b += other.values[i] * other.values[i];
    }
    return dot / (math.sqrt(a) * math.sqrt(b) + 1e-9);
  }
}

/// Loads both graphs and runs the conversion. Blocking native calls — build one
/// inside the TTS worker isolate, next to `OfflineTts`, never on the UI isolate.
class VoiceConverter {
  VoiceConverter._(this._runtime, this._encoder, this._converter, this._ownsRuntime);

  final OrtRuntime _runtime;
  final OrtSession _encoder;
  final OrtSession _converter;
  final bool _ownsRuntime;
  bool _disposed = false;

  /// Open [refEncoderPath] and [converterPath].
  ///
  /// Pass [runtime] to share the caller's (the TTS worker already has one);
  /// otherwise one is opened and owned here. [libraryPath] is desktop-dev only.
  ///
  /// [numThreads] is worth 1.75x: the same pass measures 2278 ms at 2 threads
  /// and 1302 ms at 4 on this Mac's four performance cores — the RTF 0.202 in
  /// docs/voice-cloning.md is the 4-thread figure. It is *not* free during a
  /// call, where the recogniser is already the scarce consumer of those cores
  /// (commit 4dbd333), so treat it as a dial to measure on device, not a
  /// setting to raise blind.
  static VoiceConverter open({
    required String refEncoderPath,
    required String converterPath,
    OrtRuntime? runtime,
    String? libraryPath,
    int numThreads = 4,
  }) {
    final rt = runtime ?? OrtRuntime.open(libraryPath: libraryPath);
    try {
      final encoder = rt.loadSession(refEncoderPath, numThreads: numThreads);
      try {
        final converter = rt.loadSession(converterPath, numThreads: numThreads);
        return VoiceConverter._(rt, encoder, converter, runtime == null);
      } catch (_) {
        encoder.dispose();
        rethrow;
      }
    } catch (_) {
      if (runtime == null) rt.dispose();
      rethrow;
    }
  }

  /// The rate [convert] returns audio at. The caller resamples or, better,
  /// writes the WAV header with it — the playback path takes a rate anyway.
  int get outputSampleRate => kVoiceSampleRate;

  /// Fingerprint the speaker heard in [pcm] (mono, `[-1, 1]`).
  ///
  /// Quality of this input dominates the whole feature: a reverberant room gets
  /// baked into the fingerprint and the result stops being convincing. Prefer a
  /// VAD segment of actual speech over a slice that is half silence.
  VoiceFingerprint fingerprint(Float32List pcm, {required int sampleRate}) {
    _assertLive();
    final audio = resample(pcm, sampleRate, kVoiceSampleRate);
    final spec = spectrogram(audio);
    if (spec.frames == 0) {
      throw ArgumentError('reference audio too short: ${pcm.length} samples');
    }
    final out = _encoder.run(
      {'spec': OrtInput.floats(spec.data, [1, kSpecBins, spec.frames])},
      const ['se'],
    );
    return VoiceFingerprint(out.first.data);
  }

  /// Re-voice [pcm] (the TTS output) as [target].
  ///
  /// [source] is the fingerprint of the voice actually speaking in [pcm]. It is
  /// computed from [pcm] itself when omitted, which is the adaptive choice —
  /// but a caller that always uses the same TTS voice should compute it once and
  /// pass it, saving an encoder pass per sentence.
  Float32List convert({
    required Float32List pcm,
    required int sampleRate,
    required VoiceFingerprint target,
    VoiceFingerprint? source,
    double alpha = kDefaultAlpha,
  }) {
    _assertLive();
    final audio = resample(pcm, sampleRate, kVoiceSampleRate);
    final spec = spectrogram(audio);
    if (spec.frames == 0) return Float32List(0);

    final src = source ?? fingerprint(audio, sampleRate: kVoiceSampleRate);
    final tgt = _extrapolate(src.values, target.values, alpha);

    final total = spec.frames * kHopLength;
    final out = Float32List(total);
    final step = kConverterFrames - _kChunkOverlap;
    final fadeSamples = _kChunkOverlap * kHopLength;

    for (var start = 0; start < spec.frames; start += step) {
      final valid = math.min(kConverterFrames, spec.frames - start);
      final chunk = _runConverter(
        spec.window(start, kConverterFrames),
        valid,
        src.values,
        tgt,
      );
      final offset = start * kHopLength;
      final length = math.min(valid * kHopLength, total - offset);
      final isFirst = start == 0;
      final isLast = start + step >= spec.frames;
      for (var i = 0; i < length; i++) {
        var gain = 1.0;
        if (!isFirst && i < fadeSamples) gain = i / fadeSamples;
        if (!isLast && i >= length - fadeSamples) {
          gain *= (length - i) / fadeSamples;
        }
        out[offset + i] += chunk[i] * gain;
      }
      if (isLast) break;
    }
    return out;
  }

  Float32List _runConverter(
    Float32List spec,
    int validFrames,
    Float32List seSrc,
    Float32List seTgt,
  ) {
    final res = _converter.run(
      {
        'spec': OrtInput.floats(spec, [1, kSpecBins, kConverterFrames]),
        // The graph masks past this, so a padded chunk is not read as silence
        // the model has to voice.
        'spec_lengths': OrtInput.int64s(Int64List.fromList([validFrames]), [1]),
        'se_src': OrtInput.floats(seSrc, [1, 256, 1]),
        'se_tgt': OrtInput.floats(seTgt, [1, 256, 1]),
      },
      const ['audio'],
    );
    return res.first.data;
  }

  static Float32List _extrapolate(Float32List src, Float32List tgt, double alpha) {
    final out = Float32List(256);
    for (var i = 0; i < 256; i++) {
      out[i] = src[i] + alpha * (tgt[i] - src[i]);
    }
    return out;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _converter.dispose();
    _encoder.dispose();
    if (_ownsRuntime) _runtime.dispose();
  }

  void _assertLive() {
    if (_disposed) throw StateError('VoiceConverter used after dispose');
  }
}
