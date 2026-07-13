/// Which on-device STT model serves which language.
///
/// The app ships only the engines; models are downloaded on demand — see
/// [AsrService.ensureLanguageInstalled].
///
/// - **Universal int8** (sherpa-onnx `OfflineRecognizer`) — 99 languages,
///   ~357 MB. Listed FIRST, so it now serves every language.
/// - **Neural v2** (sherpa-onnx) and **lattice** (native lib via dart:ffi) are the
///   smaller, faster per-language models that used to serve the 16 languages
///   they cover. They are kept, but unreachable while the universal entry leads the list —
///   move the universal entry back to the END to restore them.
///
/// Speaking is no longer paired with hearing: translations are spoken by the
/// device's own OS voice (`flutter_tts`), so there is no TTS catalogue to keep
/// this one in step with.
///
/// STT runs on the phone's OWN outgoing mic, so a device only ever downloads
/// the model for its user's language.
library;

enum AsrEngineKind { neural, lattice, universal }

/// On-disk id of the universal model. This is a directory name under
/// `<appSupport>/stt/`, so it is part of the installed state: an app already on
/// a phone has 357 MB sitting under [kLegacyUniversalModelId], and changing this
/// without the rename in [AsrModelDownloader] would silently re-download all of
/// it over the user's data plan.
const String kUniversalModelId = 'asr-u1';

/// Pre-rename directory name. Kept only so the migration can find it; delete
/// once no install can still be carrying it.
const String kLegacyUniversalModelId = 'whisper-small';

/// Where the voice-activity segmenter is fetched from.
///
/// Every remote source in this file still points at its upstream host, so a
/// first launch tells anyone watching the network exactly which models the app
/// runs. Re-host these behind our own domain to close that.
const String kSegmenterUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

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

  /// Folder inside [repo] holding this language's neural v2 files
  /// (one per language), all re-hosted on our own `swayco-stt-models`
  /// repo: sherpa's v2 loader wants `encoder` + `mergedDecoder` +
  /// `tokens.txt`, and the `tokens.txt` is produced offline from each model's
  /// tokenizer by the upstream generate_tokens script.
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

/// Universal: encoder + decoder + tokens, fetched file by file and stored under
/// canonical names, so the engine never has to know which variant it got.
///
/// Only the quantised graphs are fetched — the source also holds fp32, at twice
/// the size. The current variant is ~357 MB on disk; [variant] (with [repo] and
/// [approxMb]) selects a smaller one, trading accuracy for a third of the
/// download and roughly twice the speed.
class UniversalAsrSpec extends AsrModelSpec {
  const UniversalAsrSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
    required this.repo,
    required this.variant,
  });

  final String repo;

  /// The prefix the published files carry — selects the size of the graphs.
  final String variant;

  @override
  AsrEngineKind get kind => AsrEngineKind.universal;

  static const encoderFile = 'encoder.int8.onnx';
  static const decoderFile = 'decoder.int8.onnx';
  static const tokensFile = 'tokens.txt';

  /// Remote file name → the name it is saved under in the model dir.
  Map<String, String> get files => {
        '$variant-encoder.int8.onnx': encoderFile,
        '$variant-decoder.int8.onnx': decoderFile,
        '$variant-tokens.txt': tokensFile,
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
  // FIRST on purpose: [specForLang] scans in order, so the universal engine now
  // serves every language and the per-language models below are never reached.
  // They are left in place so that moving this entry back to the END restores
  // the old behaviour — per-language models for the 16 languages they cover,
  // universal for the rest — in one line.
  UniversalAsrSpec(
    id: kUniversalModelId,
    langs: _universalLangs,
    approxMb: 357,
    repo: 'csukuangfj/sherpa-onnx-whisper-small',
    variant: 'small',
  ),
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

/// The 99 languages the universal engine decodes, in the app’s own codes.
///
/// `fil` is ours, not the recogniser's — it decodes Tagalog as `tl`, which
/// [universalLangCode] translates.
const _universalLangs = <String>[
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

/// The code the recogniser itself expects for one of our language codes.
String universalLangCode(String langCode) {
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
