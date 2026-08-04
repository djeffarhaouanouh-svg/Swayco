/// Which on-device STT model serves which language.
///
/// The app ships only the engines; models are downloaded on demand — see
/// [AsrService.ensureLanguageInstalled].
///
/// - **Universal int8** (sherpa-onnx `OfflineRecognizer`) — 99 languages,
///   ~244 MB. Serves every language (OS STT is preferred first when available).
///
/// Speaking is no longer paired with hearing: translations are spoken by the
/// device's own OS voice (`flutter_tts`), so there is no TTS catalogue to keep
/// this one in step with.
///
/// STT runs on the phone's OWN outgoing mic, so a device only ever downloads
/// the model for its user's language.
library;

enum AsrEngineKind { universal }

/// On-disk id of the universal model — a directory name under
/// `<appSupport>/stt/`, and therefore part of the installed state.
///
/// Bumping it is what makes a phone fetch the new weights: the downloader keys
/// "is it installed?" on this directory, and [AsrService] prunes the others.
/// `u2` is the re-hosted build whose token-embedding table is stored int8
/// (244 MB instead of 357 — see [kUniversalRepo]).
const String kUniversalModelId = 'asr-u2';

/// Our own model mirror. Nothing here names an upstream project or a model
/// family: a phone's first launch used to announce, to anyone watching the
/// network, exactly which recogniser the app runs.
const String kUniversalRepo = 'djeffar/swayco-stt-models';

/// Where the voice-activity segmenter is fetched from — our mirror, like the
/// rest. It used to be pulled from its upstream release page under its own
/// name, which announced the VAD to anyone watching a first launch.
const String kSegmenterUrl =
    'https://huggingface.co/$kUniversalRepo/resolve/main/u1/seg.onnx';

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

/// Universal: encoder + decoder + tokens, fetched file by file from our own
/// mirror under [subdir] and kept under the same names on disk.
///
/// The published graphs are quantised twice over. The linear layers are int8,
/// which is what the upstream export ships. The token-embedding table is int8
/// too, which it does NOT: upstream leaves it fp32, because their quantiser only
/// looks at MatMul and an embedding is a Gather. That one table was 152 MB of a
/// 357 MB download — a third of the model, never compressed. Quantising it
/// per-row (one scale per token, so the CJK rows keep their range) costs nothing
/// measurable: it is a lookup table, not arithmetic. 4-bit weights, by contrast,
/// dropped whole words in ja/zh and ran 25 % slower — do not go there.
class UniversalAsrSpec extends AsrModelSpec {
  const UniversalAsrSpec({
    required super.id,
    required super.langs,
    required super.approxMb,
    required this.repo,
    this.subdir = '',
  });

  final String repo;

  /// Folder inside [repo] holding this build's files.
  final String subdir;

  @override
  AsrEngineKind get kind => AsrEngineKind.universal;

  static const encoderFile = 'encoder.onnx';
  static const decoderFile = 'decoder.onnx';
  static const tokensFile = 'tokens.txt';

  List<String> get files => const [encoderFile, decoderFile, tokensFile];

  String urlFor(String file) {
    final path = subdir.isEmpty ? file : '$subdir/$file';
    return 'https://huggingface.co/$repo/resolve/main/$path';
  }
}

const _specs = <AsrModelSpec>[
  UniversalAsrSpec(
    id: kUniversalModelId,
    langs: _universalLangs,
    approxMb: 244,
    repo: kUniversalRepo,
    subdir: 'u1',
  ),
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
