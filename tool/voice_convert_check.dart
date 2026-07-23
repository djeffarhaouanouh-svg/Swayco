// Runs the voice converter outside the app, on the ONNX Runtime the macOS
// plugin vendors. This is the fast loop for docs/voice-cloning.md: no build, no
// device, and it checks the Dart front-end against the numpy reference that
// validated the chain in the first place.
//
//   dart run tool/voice_convert_check.dart \
//     --models ~/Downloads \
//     --in docs/ja_tts_phase0_samples/fp16/fp16_03_kinou_ryouri.wav \
//     [--ref speaker.wav] [--out /tmp/converted.wav] [--golden golden.json]
//
// With no --ref it converts the input onto its OWN fingerprint: the model is
// then an identity, so the output must still sound like the input. That is the
// check that the spectrogram convention is right — a wrong one does not throw,
// it just returns noise.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:livekit_translate/swayco/speech/voice_converter.dart';
import 'package:livekit_translate/swayco/speech/voice_spectrogram.dart';

const _defaultOrt =
    'native/sherpa_onnx_macos_patched/macos/libonnxruntime.1.27.0.dylib';

void main(List<String> argv) {
  final args = _parse(argv);
  final models = args['models'] ?? Platform.environment['OPENVOICE_MODELS'];
  final inPath = args['in'];
  if (models == null || inPath == null) {
    stderr.writeln('usage: --models <dir> --in <wav> [--ref <wav>] '
        '[--out <wav>] [--golden <json>] [--alpha 1.5] [--threads 4] '
        '[--ort <dylib>] [--converter converter.onnx]');
    exit(2);
  }
  final alpha = double.tryParse(args['alpha'] ?? '') ?? kDefaultAlpha;

  final source = _readWav(inPath);
  _say('in       $inPath  ${source.sampleRate} Hz  '
      '${(source.samples.length / source.sampleRate).toStringAsFixed(2)} s');

  final converter = VoiceConverter.open(
    refEncoderPath: '$models/ref_encoder.onnx',
    // Same filename the app downloads, so a stale fixed-520 export sitting in
    // the models dir under its old name cannot be picked up by accident.
    converterPath: '$models/${args['converter'] ?? 'converter.onnx'}',
    libraryPath: args['ort'] ?? _defaultOrt,
    numThreads: int.tryParse(args['threads'] ?? '') ?? 4,
  );

  try {
    final audio = resample(source.samples, source.sampleRate, kVoiceSampleRate);
    final spec = spectrogram(audio);
    _say('spec     ${spec.frames} frames x $kSpecBins bins  '
        'sum ${spec.data.fold<double>(0, (a, b) => a + b).toStringAsFixed(1)}  '
        'max ${spec.data.reduce(math.max).toStringAsFixed(4)}');

    final own = converter.fingerprint(audio, sampleRate: kVoiceSampleRate);
    _say('se       norm ${_norm(own.values).toStringAsFixed(4)}');

    final refPath = args['ref'];
    final target = refPath == null ? own : () {
      final r = _readWav(refPath);
      _say('ref      $refPath  ${r.sampleRate} Hz  '
          '${(r.samples.length / r.sampleRate).toStringAsFixed(2)} s');
      final fp = converter.fingerprint(r.samples, sampleRate: r.sampleRate);
      _say('         similarity to source voice '
          '${fp.similarityTo(own).toStringAsFixed(3)}');
      return fp;
    }();

    final t0 = DateTime.now();
    final converted = converter.convert(
      pcm: audio,
      sampleRate: kVoiceSampleRate,
      target: target,
      source: own,
      alpha: refPath == null ? 1.0 : alpha,
    );
    final elapsed = DateTime.now().difference(t0).inMilliseconds;
    final seconds = converted.length / kVoiceSampleRate;
    _say('convert  $elapsed ms for ${seconds.toStringAsFixed(2)} s  '
        '-> RTF ${(elapsed / 1000 / seconds).toStringAsFixed(3)}'
        '${refPath == null ? "  (identity, alpha ignored)" : "  alpha $alpha"}');

    _say('audio    rms in ${_rms(audio).toStringAsFixed(4)}  '
        'out ${_rms(converted).toStringAsFixed(4)}');

    final sa = spectrogram(converted);
    _say('quality  log-spectral distance vs input '
        '${_logSpectralDistance(sa, spec).toStringAsFixed(3)}'
        '${refPath == null ? "   (identity: < 1.0 expected)" : ""}');

    final goldenPath = args['golden'];
    if (goldenPath != null) {
      _compareGolden(goldenPath, audio, spec, own.values, converted);
    }

    final outPath = args['out'];
    if (outPath != null) {
      _writeWav(outPath, converted, kVoiceSampleRate);
      _say('wrote    $outPath');
    }
  } finally {
    converter.dispose();
  }
}

// ── golden comparison ────────────────────────────────────────────────────────

void _compareGolden(
  String path,
  Float32List audio,
  Spectrogram spec,
  Float32List se,
  Float32List converted,
) {
  final g = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  var worst = 0.0;
  void cmp(String label, double dart, double ref, {double tol = 1e-3}) {
    final rel = (dart - ref).abs() / (ref.abs() + 1e-9);
    worst = math.max(worst, rel);
    _say('golden   ${label.padRight(22)} dart ${dart.toStringAsFixed(6)}  '
        'numpy ${ref.toStringAsFixed(6)}  rel ${rel.toStringAsExponential(1)}'
        '${rel > tol ? "   <-- MISMATCH" : ""}');
  }

  cmp('resampled rms', _rms(audio), (g['resampled_rms'] as num).toDouble());
  cmp('resampled len', audio.length.toDouble(),
      (g['resampled_len'] as num).toDouble());
  cmp('spec frames', spec.frames.toDouble(),
      ((g['spec_shape'] as List)[1] as num).toDouble());
  cmp('spec sum', spec.data.fold<double>(0, (a, b) => a + b),
      (g['spec_sum'] as num).toDouble());

  final refSe = (g['se'] as List).map((v) => (v as num).toDouble()).toList();
  var dot = 0.0, a = 0.0, b = 0.0, maxAbs = 0.0;
  for (var i = 0; i < 256; i++) {
    dot += se[i] * refSe[i];
    a += se[i] * se[i];
    b += refSe[i] * refSe[i];
    maxAbs = math.max(maxAbs, (se[i] - refSe[i]).abs());
  }
  final cos = dot / (math.sqrt(a) * math.sqrt(b) + 1e-9);
  _say('golden   fingerprint           cosine ${cos.toStringAsFixed(6)}  '
      'max abs diff ${maxAbs.toStringAsExponential(1)}'
      '${cos < 0.9999 ? "   <-- MISMATCH" : ""}');

  if (g['audio_rms'] != null) {
    cmp('converted rms', _rms(converted), (g['audio_rms'] as num).toDouble(),
        tol: 0.02);
  }
  _say(worst > 1e-3 || cos < 0.9999
      ? 'RESULT   front-end does NOT match the numpy reference'
      : 'RESULT   front-end matches the numpy reference');
}

// ── helpers ──────────────────────────────────────────────────────────────────

double _rms(Float32List x) {
  if (x.isEmpty) return 0;
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return math.sqrt(s / x.length);
}

double _norm(Float32List x) {
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return math.sqrt(s);
}

double _logSpectralDistance(Spectrogram a, Spectrogram b) {
  final frames = math.min(a.frames, b.frames);
  if (frames == 0) return double.nan;
  var acc = 0.0;
  var n = 0;
  for (var bin = 0; bin < kSpecBins; bin++) {
    for (var f = 0; f < frames; f++) {
      final d = math.log(a.at(bin, f) + 1e-5) - math.log(b.at(bin, f) + 1e-5);
      acc += d * d;
      n++;
    }
  }
  return math.sqrt(acc / n);
}

void _say(String s) => stdout.writeln('[voice] $s');

Map<String, String> _parse(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final eq = a.indexOf('=');
    if (eq > 0) {
      out[a.substring(2, eq)] = a.substring(eq + 1);
    } else if (i + 1 < argv.length) {
      out[a.substring(2)] = argv[++i];
    }
  }
  return out;
}

class _Wav {
  const _Wav(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;
}

/// Minimal 16-bit PCM WAV reader — enough for the samples in this repo and for
/// anything `_writeWav` produces. Mixes down to mono.
_Wav _readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  if (bytes.length < 12 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw FormatException('not a WAV file: $path');
  }
  var offset = 12;
  var channels = 1, rate = kVoiceSampleRate, bits = 16;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      channels = view.getUint16(body + 2, Endian.little);
      rate = view.getUint32(body + 4, Endian.little);
      bits = view.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (bits != 16) throw FormatException('only 16-bit PCM: $path ($bits)');
      final count = size ~/ 2;
      final frames = count ~/ channels;
      final out = Float32List(frames);
      for (var f = 0; f < frames; f++) {
        var acc = 0.0;
        for (var c = 0; c < channels; c++) {
          acc += view.getInt16(body + (f * channels + c) * 2, Endian.little) /
              32768.0;
        }
        out[f] = acc / channels;
      }
      return _Wav(out, rate);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  throw FormatException('no data chunk in $path');
}

void _writeWav(String path, Float32List samples, int sampleRate) {
  final data = ByteData(44 + samples.length * 2);
  var o = 0;
  void u8(int v) => data.setUint8(o++, v);
  void tag(String s) => s.codeUnits.forEach(u8);
  void u16(int v) {
    data.setUint16(o, v, Endian.little);
    o += 2;
  }

  void u32(int v) {
    data.setUint32(o, v, Endian.little);
    o += 4;
  }

  tag('RIFF');
  u32(36 + samples.length * 2);
  tag('WAVE');
  tag('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  tag('data');
  u32(samples.length * 2);
  for (final s in samples) {
    data.setInt16(o, (s.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    o += 2;
  }
  File(path).writeAsBytesSync(data.buffer.asUint8List());
}
