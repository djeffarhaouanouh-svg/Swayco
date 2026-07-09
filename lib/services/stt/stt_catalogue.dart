/// Which on-device STT model serves which language.
///
/// The app ships only the engines; models are downloaded on demand — see
/// [SttService.ensureLanguageInstalled]. Two engines:
///
/// - **Moonshine** (ONNX Runtime, already a dependency for Kokoro TTS) —
///   `en`, `ja`, `zh`, `ko`, `ar`.
/// - **Vosk** (libvosk via dart:ffi) — `fr`, `ru`, `es`, `it`, `pt`, `de`, `nl`.
///
/// STT runs on the phone's OWN outgoing mic, so a device only ever downloads
/// the model for its user's language — one model, 30–60 MB.
library;

enum SttEngineKind { moonshine, vosk }

sealed class SttModelSpec {
  const SttModelSpec({
    required this.id,
    required this.langs,
    required this.approxMb,
  });

  /// Directory name under `<appSupport>/stt/`.
  final String id;
  final List<String> langs;
  final int approxMb;

  SttEngineKind get kind;
}

/// Moonshine: encoder + decoder ONNX graphs and a BPE tokenizer, fetched file
/// by file from a Hugging Face repo (same pattern as the Kokoro downloader).
class MoonshineSpec extends SttModelSpec {
  const MoonshineSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
    required this.repo,
    this.subdir = '',
  });

  final String repo;

  /// Path inside [repo]. Empty for the upstream `onnx-community/*` repos, which
  /// hold a single model at the root. Our own `swayco-stt-models` repo keeps one
  /// folder per model (ko, ar — exported by `scripts/export_moonshine_onnx.sh`,
  /// since UsefulSensors publishes those two as PyTorch only).
  final String subdir;

  @override
  SttEngineKind get kind => SttEngineKind.moonshine;

  static const encoderFile = 'onnx/encoder_model_quantized.onnx';
  static const decoderFile = 'onnx/decoder_model_quantized.onnx';
  static const tokenizerFile = 'tokenizer.json';

  List<String> get files => const [encoderFile, decoderFile, tokenizerFile];

  String urlFor(String file) {
    final path = subdir.isEmpty ? file : '$subdir/$file';
    return 'https://huggingface.co/$repo/resolve/main/$path';
  }
}

/// Vosk: one zip per language, expanded into `<appSupport>/stt/<id>/`.
class VoskSpec extends SttModelSpec {
  const VoskSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
  });

  @override
  SttEngineKind get kind => SttEngineKind.vosk;

  String get zipUrl => 'https://alphacephei.com/vosk/models/$id.zip';
}

const _specs = <SttModelSpec>[
  MoonshineSpec(
    id: 'moonshine-tiny-en',
    langs: ['en'],
    approxMb: 50,
    repo: 'onnx-community/moonshine-tiny-ONNX',
  ),
  MoonshineSpec(
    id: 'moonshine-tiny-ja',
    langs: ['ja'],
    approxMb: 50,
    repo: 'onnx-community/moonshine-tiny-ja-ONNX',
  ),
  MoonshineSpec(
    id: 'moonshine-tiny-zh',
    langs: ['zh'],
    approxMb: 50,
    repo: 'onnx-community/moonshine-tiny-zh-ONNX',
  ),
  MoonshineSpec(
    id: 'moonshine-tiny-ko',
    langs: ['ko'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-tiny-ko',
  ),
  MoonshineSpec(
    id: 'moonshine-tiny-ar',
    langs: ['ar'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-tiny-ar',
  ),
  VoskSpec(id: 'vosk-model-small-fr-0.22', langs: ['fr'], approxMb: 41),
  VoskSpec(id: 'vosk-model-small-ru-0.22', langs: ['ru'], approxMb: 45),
  VoskSpec(id: 'vosk-model-small-es-0.42', langs: ['es'], approxMb: 39),
  VoskSpec(id: 'vosk-model-small-it-0.22', langs: ['it'], approxMb: 48),
  VoskSpec(id: 'vosk-model-small-pt-0.3', langs: ['pt'], approxMb: 31),
  VoskSpec(id: 'vosk-model-small-de-0.15', langs: ['de'], approxMb: 45),
  VoskSpec(id: 'vosk-model-small-nl-0.22', langs: ['nl'], approxMb: 39),
];

String normalizeLang(String langCode) =>
    langCode.toLowerCase().split(RegExp(r'[-_]')).first;

/// The model serving [langCode], or null when the language has no on-device
/// engine (callers keep the previous behaviour rather than failing the call).
SttModelSpec? specForLang(String langCode) {
  final lc = normalizeLang(langCode);
  for (final s in _specs) {
    if (s.langs.contains(lc)) return s;
  }
  return null;
}

/// Languages that can run fully on-device.
Iterable<String> get supportedLangs => _specs.expand((s) => s.langs);
