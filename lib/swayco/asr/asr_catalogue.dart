/// Which on-device STT model serves which language.
///
/// The app ships only the engines; models are downloaded on demand — see
/// [AsrService.ensureLanguageInstalled]. Two engines:
///
/// - **The neural engine** (Moonshine v2 on sherpa-onnx, the same runtime the
///   on-device TTS uses) — `en`, `ja`, `zh`, `ko`, `ar`.
/// - **Vosk** (libvosk via dart:ffi) — `fr`, `ru`, `es`, `it`, `pt`, `de`, `nl`,
///   `pl`, `tr`, `uk`, `hi`.
///
/// Every language here also has a voice in [tts_catalogue] — the two lists must
/// stay in step, since a language that can only be heard (or only spoken) breaks
/// one direction of a call. `supportedLanguages` is their intersection.
///
/// STT runs on the phone's OWN outgoing mic, so a device only ever downloads
/// the model for its user's language — one model, 30–140 MB.
library;

enum AsrEngineKind { neural, lattice }

sealed class AsrModelSpec {
  const AsrModelSpec({
    required this.id,
    required this.langs,
    required this.approxMb,
  });

  /// Directory name under `<appSupport>/stt/`.
  final String id;
  final List<String> langs;
  final int approxMb;

  AsrEngineKind get kind;
}

/// Neural: encoder + decoder ONNX graphs and a BPE tokenizer, fetched file
/// by file from a Hugging Face repo (same pattern as the local TTS engine downloader).
class NeuralAsrSpec extends AsrModelSpec {
  const NeuralAsrSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
    required this.repo,
    this.subdir = '',
  });

  final String repo;

  /// Folder inside [repo] holding this language's Moonshine v2 files
  /// (`moonshine-v2-<lang>/`), all re-hosted on our own `swayco-stt-models`
  /// repo: sherpa's Moonshine v2 loader wants `encoder` + `mergedDecoder` +
  /// `tokens.txt`, and the `tokens.txt` is produced offline from each model's
  /// tokenizer by `sherpa-onnx/scripts/moonshine/v2/generate_tokens.py`.
  final String subdir;

  @override
  AsrEngineKind get kind => AsrEngineKind.neural;

  static const encoderFile = 'encoder.onnx';
  static const mergedDecoderFile = 'decoder_merged.onnx';
  static const tokensFile = 'tokens.txt';

  List<String> get files =>
      const [encoderFile, mergedDecoderFile, tokensFile];

  String urlFor(String file) {
    final path = subdir.isEmpty ? file : '$subdir/$file';
    return 'https://huggingface.co/$repo/resolve/main/$path';
  }
}

/// Lattice: one zip per language, expanded into `<appSupport>/stt/<id>/`.
class LatticeAsrSpec extends AsrModelSpec {
  const LatticeAsrSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
  });

  @override
  AsrEngineKind get kind => AsrEngineKind.lattice;

  String get zipUrl => 'https://alphacephei.com/vosk/models/$id.zip';
}

const _specs = <AsrModelSpec>[
  NeuralAsrSpec(
    id: 'moonshine-v2-en',
    langs: ['en'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-v2-en',
  ),
  NeuralAsrSpec(
    id: 'moonshine-v2-ja',
    langs: ['ja'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-v2-ja',
  ),
  NeuralAsrSpec(
    id: 'moonshine-v2-zh',
    langs: ['zh'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-v2-zh',
  ),
  NeuralAsrSpec(
    id: 'moonshine-v2-ko',
    langs: ['ko'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-v2-ko',
  ),
  NeuralAsrSpec(
    id: 'moonshine-v2-ar',
    langs: ['ar'],
    approxMb: 50,
    repo: 'djeffar/swayco-stt-models',
    subdir: 'moonshine-v2-ar',
  ),
  LatticeAsrSpec(id: 'vosk-model-small-fr-0.22', langs: ['fr'], approxMb: 41),
  LatticeAsrSpec(id: 'vosk-model-small-ru-0.22', langs: ['ru'], approxMb: 45),
  LatticeAsrSpec(id: 'vosk-model-small-es-0.42', langs: ['es'], approxMb: 39),
  LatticeAsrSpec(id: 'vosk-model-small-it-0.22', langs: ['it'], approxMb: 48),
  LatticeAsrSpec(id: 'vosk-model-small-pt-0.3', langs: ['pt'], approxMb: 31),
  LatticeAsrSpec(id: 'vosk-model-small-de-0.15', langs: ['de'], approxMb: 45),
  LatticeAsrSpec(id: 'vosk-model-small-nl-0.22', langs: ['nl'], approxMb: 39),
  // Languages that already had a Piper voice but no way to be heard. Swedish is
  // deliberately absent: Vosk's only "small" Swedish model is 289 MB, 6x the
  // others — too heavy to hand a user at onboarding.
  LatticeAsrSpec(id: 'vosk-model-small-pl-0.22', langs: ['pl'], approxMb: 50),
  LatticeAsrSpec(id: 'vosk-model-small-tr-0.3', langs: ['tr'], approxMb: 35),
  LatticeAsrSpec(id: 'vosk-model-small-uk-v3-small', langs: ['uk'], approxMb: 137),
  LatticeAsrSpec(id: 'vosk-model-small-hi-0.22', langs: ['hi'], approxMb: 42),
];

String normalizeLang(String langCode) =>
    langCode.toLowerCase().split(RegExp(r'[-_]')).first;

/// The model serving [langCode], or null when the language has no on-device
/// engine (callers keep the previous behaviour rather than failing the call).
AsrModelSpec? specForLang(String langCode) {
  final lc = normalizeLang(langCode);
  for (final s in _specs) {
    if (s.langs.contains(lc)) return s;
  }
  return null;
}

/// Languages that can run fully on-device.
Iterable<String> get supportedLangs => _specs.expand((s) => s.langs);
