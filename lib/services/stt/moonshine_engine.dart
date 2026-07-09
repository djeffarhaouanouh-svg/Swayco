import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';

import 'moonshine_tokenizer.dart';
import 'stt_engine_native.dart';

/// Moonshine ASR on ONNX Runtime — the same runtime Kokoro TTS already uses,
/// so no second native library enters the build.
///
/// Moonshine takes the raw 16 kHz waveform (no mel front-end) through an
/// encoder, then greedily decodes tokens conditioned on the encoder states.
/// We run the **uncached** decoder and re-feed the whole prefix each step. A
/// KV-cached decoder would be asymptotically faster, but utterances here are
/// VAD-clipped to a few seconds (tens of tokens) and the uncached graph avoids
/// threading a dozen past_key_values tensors through dart:ffi by hand.
class MoonshineEngine implements SttEngine {
  OrtSession? _encoder;
  OrtSession? _decoder;
  MoonshineTokenizer? _tok;
  bool _busy = false;

  /// Moonshine's decoder starts on `<s>` and stops on `</s>`.
  static const _bosTokenId = 1;
  static const _eosTokenId = 2;

  /// ~6 words/s of speech at 16 kHz; a 15 s utterance never needs more.
  static const _maxNewTokens = 160;

  @override
  Future<void> load(String modelDir, String lang) async {
    OrtEnv.instance.init();
    final opts = OrtSessionOptions();
    _encoder = OrtSession.fromFile(
        File('$modelDir/encoder_model_quantized.onnx'), opts);
    _decoder = OrtSession.fromFile(
        File('$modelDir/decoder_model_quantized.onnx'), opts);
    _tok = await MoonshineTokenizer.load('$modelDir/tokenizer.json');
  }

  @override
  bool get isReady => _encoder != null && _decoder != null && _tok != null;

  @override
  Future<String> transcribe(Float32List samples16k) async {
    final encoder = _encoder;
    final decoder = _decoder;
    final tok = _tok;
    if (encoder == null || decoder == null || tok == null) return '';
    // Drop overlapping requests rather than queueing: a stale utterance decoded
    // late would be published after the one that followed it.
    if (_busy || samples16k.isEmpty) return '';
    _busy = true;

    final tensors = <OrtValue>[];
    try {
      final audio = OrtValueTensor.createTensorWithDataList(
        samples16k,
        [1, samples16k.length],
      );
      tensors.add(audio);

      // Graph signatures differ by provenance: the onnx-community exports
      // (en/ja/zh) take the waveform alone, while an optimum re-export
      // (ko/ar, scripts/export_moonshine_onnx.sh) also declares an
      // attention_mask. Feed a mask only when the graph asks for one —
      // passing an undeclared input makes ORT throw.
      final encInputs = <String, OrtValue>{'input_values': audio};
      if (encoder.inputNames.contains('attention_mask')) {
        final mask = OrtValueTensor.createTensorWithDataList(
          Int64List(samples16k.length)..fillRange(0, samples16k.length, 1),
          [1, samples16k.length],
        );
        tensors.add(mask);
        encInputs['attention_mask'] = mask;
      }

      final encOut = await encoder.runAsync(OrtRunOptions(), encInputs);
      if (encOut == null || encOut.isEmpty) return '';
      final hidden = _flatten(encOut.first?.value);
      final encLen = _lastDimCount(encOut.first?.value);
      for (final v in encOut) {
        v?.release();
      }
      if (hidden == null || encLen == 0) return '';
      final frames = hidden.length ~/ encLen;

      final ids = <int>[_bosTokenId];
      for (var step = 0; step < _maxNewTokens; step++) {
        final inputIds = OrtValueTensor.createTensorWithDataList(
          Int64List.fromList(ids),
          [1, ids.length],
        );
        final encStates = OrtValueTensor.createTensorWithDataList(
          hidden,
          [1, frames, encLen],
        );

        final decInputs = <String, OrtValue>{
          'input_ids': inputIds,
          'encoder_hidden_states': encStates,
        };
        // Same divergence as the encoder. The decoder's mask is one entry per
        // encoder *frame* (the waveform is downsampled 400×), not per sample.
        OrtValueTensor? encMask;
        if (decoder.inputNames.contains('encoder_attention_mask')) {
          encMask = OrtValueTensor.createTensorWithDataList(
            Int64List(frames)..fillRange(0, frames, 1),
            [1, frames],
          );
          decInputs['encoder_attention_mask'] = encMask;
        }

        final out = await decoder.runAsync(OrtRunOptions(), decInputs);
        inputIds.release();
        encStates.release();
        encMask?.release();
        if (out == null || out.isEmpty) break;

        final logits = _flatten(out.first?.value);
        final vocab = _lastDimCount(out.first?.value);
        for (final v in out) {
          v?.release();
        }
        if (logits == null || vocab == 0) break;

        // Logits are [1, seq, vocab]; only the last position predicts the next
        // token, so argmax over the final row.
        final next = _argmax(logits, logits.length - vocab, vocab);
        if (next == _eosTokenId) break;
        ids.add(next);
      }

      return tok.decode(ids.skip(1));
    } catch (e) {
      debugPrint('[moonshine] transcribe error: $e');
      return '';
    } finally {
      for (final t in tensors) {
        t.release();
      }
      _busy = false;
    }
  }

  int _argmax(Float32List data, int offset, int count) {
    var best = 0;
    var bestVal = data[offset];
    for (var i = 1; i < count; i++) {
      final v = data[offset + i];
      if (v > bestVal) {
        bestVal = v;
        best = i;
      }
    }
    return best;
  }

  /// ORT hands back nested `List`s mirroring the tensor shape. Flatten depth-first.
  Float32List? _flatten(dynamic value) {
    if (value == null) return null;
    if (value is Float32List) return value;
    final out = <double>[];
    void walk(dynamic v) {
      if (v is num) {
        out.add(v.toDouble());
      } else if (v is List) {
        for (final e in v) {
          walk(e);
        }
      }
    }

    walk(value);
    return out.isEmpty ? null : Float32List.fromList(out);
  }

  /// Size of the innermost dimension (hidden size, or vocab size).
  int _lastDimCount(dynamic value) {
    dynamic v = value;
    while (v is List && v.isNotEmpty && v.first is List) {
      v = v.first;
    }
    return v is List ? v.length : 0;
  }

  @override
  Future<void> dispose() async {
    _encoder?.release();
    _decoder?.release();
    _encoder = null;
    _decoder = null;
    _tok = null;
  }
}
