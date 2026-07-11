/// Which on-device STT model serves which language.
///
/// The app ships only the engines; models are downloaded on demand — see
/// [AsrService.ensureLanguageInstalled]. Two engines:
///
/// - **The neural engine** (Moonshine v2 on sherpa-onnx, the same runtime the
///   on-device TTS uses) — `en`, `ja`, `zh`, `ko`, `ar`.
/// - **Vosk** (libvosk via dart:ffi) — `fr`, `ru`, `es`, `it`, `pt`, `de`, `nl`.
/// - **Whisper base int8** (sherpa-onnx `OfflineRecognizer`) — the universal
///   fallback: one model, 99 languages, for every language the two above do not
///   cover. Bigger (~152 MB) and autoregressive (slower) than the dedicated
///   models, so [specForLang] only reaches it once the per-language specs miss.
///
/// STT runs on the phone's OWN outgoing mic, so a device only ever downloads
/// the model for its user's language — one model, 30–150 MB.
library;

enum AsrEngineKind { neural, lattice, whisper }

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

/// Whisper: encoder + decoder + tokens, fetched file by file from the sherpa
/// author's Hugging Face repo and stored under canonical names so the engine
/// does not have to know which Whisper size it got.
///
/// Only the `int8` graphs are fetched (the repo also holds fp32, twice the
/// size): base int8 is ~152 MB on disk, which is the whole point of picking
/// `base` — one model for the 87 languages that have no dedicated spec.
class WhisperAsrSpec extends AsrModelSpec {
  const WhisperAsrSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
    required this.repo,
    required this.size,
  });

  final String repo;

  /// `tiny` | `base` | `small` … — the prefix the release files carry.
  final String size;

  @override
  AsrEngineKind get kind => AsrEngineKind.whisper;

  static const encoderFile = 'encoder.int8.onnx';
  static const decoderFile = 'decoder.int8.onnx';
  static const tokensFile = 'tokens.txt';

  /// Remote file name → the name it is saved under in the model dir.
  Map<String, String> get files => {
        '$size-encoder.int8.onnx': encoderFile,
        '$size-decoder.int8.onnx': decoderFile,
        '$size-tokens.txt': tokensFile,
      };

  String urlFor(String remoteFile) =>
      'https://huggingface.co/$repo/resolve/main/$remoteFile';
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

  // LAST on purpose: [specForLang] scans in order, so every language above keeps
  // its dedicated (smaller, faster) model and Whisper only serves the rest.
  WhisperAsrSpec(
    id: 'whisper-base',
    langs: _whisperLangs,
    approxMb: 152,
    repo: 'csukuangfj/sherpa-onnx-whisper-base',
    size: 'base',
  ),
];

/// The 99 languages Whisper decodes, in the app's own codes.
///
/// `fil` is ours, not Whisper's — it decodes Tagalog as `tl`; [whisperLangCode]
/// does the translation. The languages already served by Moonshine or Vosk are
/// deliberately left in: a language never reaches this spec (they are matched
/// first), but listing them keeps [supportedLangs] honest.
const _whisperLangs = <String>[
  'en', 'zh', 'de', 'es', 'ru', 'ko', 'fr', 'ja', 'pt', 'tr', 'pl', 'ca', 'nl',
  'ar', 'sv', 'it', 'id', 'hi', 'fi', 'vi', 'he', 'uk', 'el', 'ms', 'cs', 'ro',
  'da', 'hu', 'ta', 'no', 'th', 'ur', 'hr', 'bg', 'lt', 'la', 'mi', 'ml', 'cy',
  'sk', 'te', 'fa', 'lv', 'bn', 'sr', 'az', 'sl', 'kn', 'et', 'mk', 'br', 'eu',
  'is', 'hy', 'ne', 'mn', 'bs', 'kk', 'sq', 'sw', 'gl', 'mr', 'pa', 'si', 'km',
  'sn', 'yo', 'so', 'af', 'oc', 'ka', 'be', 'tg', 'sd', 'gu', 'am', 'yi', 'lo',
  'uz', 'fo', 'ht', 'ps', 'tk', 'nn', 'mt', 'sa', 'lb', 'my', 'bo', 'tl', 'mg',
  'as', 'tt', 'haw', 'ln', 'ha', 'ba', 'jw', 'su',
  'fil', // → decoded as 'tl'
];

/// The code Whisper itself expects for one of our language codes.
String whisperLangCode(String langCode) {
  final lc = normalizeLang(langCode);
  return lc == 'fil' ? 'tl' : lc;
}

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
