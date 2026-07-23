/// The signal front-end of the voice converter: resampling to 22 050 Hz and the
/// linear spectrogram the OpenVoice graphs take as input.
///
/// Both graphs consume `spec` — 513 magnitude bins per frame — and **not** raw
/// audio, so this file is what stands between the TTS samples and the model.
/// The convention is VITS' `spectrogram_torch`, which is what OpenVoice was
/// trained with; getting it wrong does not fail loudly, it just produces noise.
/// It is therefore pinned here and checked against a numpy reference by
/// `tool/voice_convert_check.dart`:
///
///   * reflect-pad by `(nFft - hop) / 2 = 384` on each side, then frame with
///     `centre = false` (the padding *is* the centring),
///   * periodic Hann window of 1024,
///   * magnitude `sqrt(re² + im² + 1e-6)` — the epsilon is inside the sqrt, so
///     digital silence is 1e-3, not 0.
///
/// Everything here is pure Dart on the CPU and costs ~5 MFLOP for a 6 s
/// sentence — three orders of magnitude under the converter itself, so there is
/// no reason to push it into native code.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// The rate both OpenVoice graphs were trained at. TTS voices are 22 050 Hz
/// (Piper) or 44 100 Hz (the ja model) and the mic is usually 16 000 Hz, so
/// [resample] runs on nearly every path.
const int kVoiceSampleRate = 22050;

const int kNFft = 1024;
const int kHopLength = 256;
const int kWinLength = 1024;

/// Number of magnitude bins: `nFft / 2 + 1`.
const int kSpecBins = kNFft ~/ 2 + 1;

/// Windowed-sinc resampler, [taps] source samples on each side.
///
/// Linear interpolation would be cheaper but it images: upsampling a 16 kHz mic
/// segment to 22 050 Hz would smear energy into the 8–11 kHz band the reference
/// encoder then bakes into the speaker fingerprint. The fingerprint is the one
/// thing in this pipeline that must not carry an artefact of the capture chain
/// (see the bathroom-reverb note in docs/voice-cloning.md), so the front-end
/// pays for a proper filter.
Float32List resample(Float32List input, int from, int to, {int taps = 32}) {
  if (from == to || input.isEmpty) return Float32List.fromList(input);
  final ratio = to / from;
  // Cut off at the lower of the two Nyquists, expressed in source cycles/sample.
  final cutoff = 0.5 * math.min(1.0, ratio);
  final n = (input.length * ratio).floor();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final centre = i / ratio;
    final first = centre.floor() - taps + 1;
    var acc = 0.0;
    var norm = 0.0;
    for (var k = 0; k < 2 * taps; k++) {
      final j = first + k;
      final t = centre - j;
      if (t.abs() >= taps) continue;
      final double sinc;
      if (t == 0) {
        sinc = 2 * cutoff;
      } else {
        sinc = math.sin(2 * math.pi * cutoff * t) / (math.pi * t);
      }
      final w = 0.5 + 0.5 * math.cos(math.pi * t / taps);
      final g = sinc * w;
      norm += g;
      if (j >= 0 && j < input.length) acc += input[j] * g;
    }
    out[i] = norm == 0 ? 0 : acc / norm;
  }
  return out;
}

/// The linear spectrogram of [samples] (22 050 Hz mono, `[-1, 1]`).
///
/// Returned flat in the models' layout — `[513][frames]`, bin-major — so it can
/// go straight into an ONNX tensor of shape `[1, 513, frames]`.
class Spectrogram {
  Spectrogram(this.data, this.frames);

  final Float32List data;
  final int frames;

  double at(int bin, int frame) => data[bin * frames + frame];
}

/// Compute the spectrogram of [samples]. See the library doc for the exact
/// convention — it is not free to change.
Spectrogram spectrogram(Float32List samples) {
  const pad = (kNFft - kHopLength) ~/ 2;
  final padded = _reflectPad(samples, pad);
  final frames = padded.length < kNFft ? 0 : 1 + (padded.length - kNFft) ~/ kHopLength;
  final out = Float32List(kSpecBins * frames);
  if (frames == 0) return Spectrogram(out, 0);

  final fft = _Fft(kNFft);
  final window = _hannPeriodic(kWinLength);
  final re = Float64List(kNFft);
  final im = Float64List(kNFft);

  for (var f = 0; f < frames; f++) {
    final offset = f * kHopLength;
    for (var i = 0; i < kNFft; i++) {
      re[i] = padded[offset + i] * window[i];
      im[i] = 0;
    }
    fft.transform(re, im);
    for (var bin = 0; bin < kSpecBins; bin++) {
      final r = re[bin], m = im[bin];
      out[bin * frames + f] = math.sqrt(r * r + m * m + 1e-6);
    }
  }
  return Spectrogram(out, frames);
}

/// How many spectrogram frames [sampleCount] samples produce — the inverse of
/// `frames * hop`, used to size and trim converted audio without running an FFT.
int framesForSamples(int sampleCount) {
  const pad = (kNFft - kHopLength) ~/ 2;
  final total = sampleCount + 2 * pad;
  if (total < kNFft) return 0;
  return 1 + (total - kNFft) ~/ kHopLength;
}

Float64List _hannPeriodic(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  return w;
}

Float32List _reflectPad(Float32List x, int pad) {
  if (x.isEmpty) return Float32List(0);
  final out = Float32List(x.length + 2 * pad);
  for (var i = 0; i < pad; i++) {
    // numpy's 'reflect': the edge sample is not repeated.
    out[i] = x[_mirror(pad - i, x.length)];
    out[out.length - 1 - i] = x[_mirror(x.length - 1 - (pad - i), x.length)];
  }
  out.setRange(pad, pad + x.length, x);
  return out;
}

int _mirror(int i, int n) {
  if (n == 1) return 0;
  final period = 2 * (n - 1);
  var k = i % period;
  if (k < 0) k += period;
  return k < n ? k : period - k;
}

/// Iterative radix-2 FFT. [size] must be a power of two.
class _Fft {
  _Fft(this.size)
      : _cos = Float64List(size ~/ 2),
        _sin = Float64List(size ~/ 2),
        _reverse = Uint16List(size) {
    for (var i = 0; i < size ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / size);
      _sin[i] = math.sin(-2 * math.pi * i / size);
    }
    final bits = size.bitLength - 1;
    for (var i = 0; i < size; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _reverse[i] = r;
    }
  }

  final int size;
  final Float64List _cos;
  final Float64List _sin;
  final Uint16List _reverse;

  /// In-place transform of [re] / [im], both of length [size].
  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < size; i++) {
      final j = _reverse[i];
      if (j > i) {
        var t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }
    for (var len = 2; len <= size; len <<= 1) {
      final half = len ~/ 2;
      final step = size ~/ len;
      for (var i = 0; i < size; i += len) {
        var k = 0;
        for (var j = i; j < i + half; j++) {
          final c = _cos[k], s = _sin[k];
          final xr = re[j + half] * c - im[j + half] * s;
          final xi = re[j + half] * s + im[j + half] * c;
          re[j + half] = re[j] - xr;
          im[j + half] = im[j] - xi;
          re[j] += xr;
          im[j] += xi;
          k += step;
        }
      }
    }
  }
}
