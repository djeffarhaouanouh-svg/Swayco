/// Which on-device TTS model serves which language, and on which engine.
///
/// Shaped like [asr_catalogue]: the app ships only the sherpa-onnx runtime;
/// the model bundle for the user's peer language is downloaded on first use and
/// cached. A device speaks exactly one language (the peer's), so it only ever
/// downloads one bundle.
///
/// Priority is "Kokoro first, else Piper/VITS": Kokoro covers most languages
/// with one multilingual model; Piper (VITS) fills the gaps and the languages
/// where a dedicated voice sounds better. Each sherpa TTS bundle is a `.tar.bz2`
/// that already contains its own `espeak-ng-data/`, so nothing phonetic ships in
/// the app binary.
///
/// ⚠️ DATA TO CONFIRM before shipping (these are values, not code — a wrong one
/// is a runtime 404 or a wrong voice, never a compile error):
///   • [bundleUrl] — verify each asset exists on sherpa's release page (or
///     re-host on `djeffar/swayco-stt-models`). The big Kokoro multi-lang bundle
///     is ~300 MB; Piper voices are ~60 MB — a real download-size trade-off.
///   • [sid] — the speaker index inside a multi-speaker/voices file; confirm the
///     per-language voice on device.
///   • the exact filenames inside each bundle ([modelFile], [voicesFile], …).
library;

import 'sherpa_tts_engine.dart' show SwayTtsEngineKind;

const _sherpaTts =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

class TtsModelSpec {
  const TtsModelSpec({
    required this.id,
    required this.langs,
    required this.engine,
    required this.approxMb,
    required this.bundleUrl,
    required this.modelFile,
    required this.tokensFile,
    this.dataDir = 'espeak-ng-data',
    this.voicesFile = '',
    this.lexiconFiles = const [],
    this.lang = '',
    this.sid = 0,
    this.speed = 1.0,
  });

  /// Directory name under `<appSupport>/tts/`.
  final String id;
  final List<String> langs;
  final SwayTtsEngineKind engine;
  final int approxMb;

  /// A single `.tar.bz2` whose one top-level folder is flattened into the id dir.
  final String bundleUrl;

  // Paths BELOW are relative to the flattened install dir.
  final String modelFile;
  final String tokensFile;
  final String dataDir;
  final String voicesFile; // Kokoro only
  final List<String> lexiconFiles; // optional, joined with ',' for sherpa
  final String lang; // Kokoro language hint
  final int sid; // speaker index
  final double speed;
}

/// Kokoro multilingual: one model, many voices — the default for every language
/// it covers. Big (~300 MB) but a device downloads it once, for one language.
const _kokoroMultiLang = 'kokoro-multi-lang-v1_1';

const _specs = <TtsModelSpec>[
  // ── Kokoro (default) ───────────────────────────────────────────────────────
  // Covers en, fr, ja, zh, es, pt, it, hi… via per-language [sid]/[lang].
  // Chinese needs a jieba dict the current Dart binding does not wire, so zh may
  // be limited — flagged for on-device check.
  TtsModelSpec(
    id: _kokoroMultiLang,
    langs: ['ja', 'zh', 'en', 'es', 'pt', 'it', 'hi'],
    engine: SwayTtsEngineKind.kokoro,
    approxMb: 320,
    bundleUrl: '$_sherpaTts/$_kokoroMultiLang.tar.bz2',
    modelFile: 'model.onnx',
    voicesFile: 'voices.bin',
    tokensFile: 'tokens.txt',
    lexiconFiles: ['lexicon-us-en.txt', 'lexicon-zh.txt'],
    sid: 0,
  ),

  // ── Piper / VITS (per the requested matrix: fr, ru, ar, uk) ─────────────────
  TtsModelSpec(
    id: 'vits-piper-fr_FR-siwis-medium',
    langs: ['fr'],
    engine: SwayTtsEngineKind.vits,
    approxMb: 63,
    bundleUrl: '$_sherpaTts/vits-piper-fr_FR-siwis-medium.tar.bz2',
    modelFile: 'fr_FR-siwis-medium.onnx',
    tokensFile: 'tokens.txt',
  ),
  TtsModelSpec(
    id: 'vits-piper-ru_RU-dmitri-medium',
    langs: ['ru'],
    engine: SwayTtsEngineKind.vits,
    approxMb: 63,
    bundleUrl: '$_sherpaTts/vits-piper-ru_RU-dmitri-medium.tar.bz2',
    modelFile: 'ru_RU-dmitri-medium.onnx',
    tokensFile: 'tokens.txt',
  ),
  TtsModelSpec(
    id: 'vits-piper-ar_JO-kareem-medium',
    langs: ['ar'],
    engine: SwayTtsEngineKind.vits,
    approxMb: 63,
    bundleUrl: '$_sherpaTts/vits-piper-ar_JO-kareem-medium.tar.bz2',
    modelFile: 'ar_JO-kareem-medium.onnx',
    tokensFile: 'tokens.txt',
  ),
  TtsModelSpec(
    id: 'vits-piper-uk_UA-ukrainian_tts-medium',
    langs: ['uk'],
    engine: SwayTtsEngineKind.vits,
    approxMb: 63,
    bundleUrl: '$_sherpaTts/vits-piper-uk_UA-ukrainian_tts-medium.tar.bz2',
    modelFile: 'uk_UA-ukrainian_tts-medium.onnx',
    tokensFile: 'tokens.txt',
  ),

  // ── Korean → mimic3 VITS (no quality Piper Korean; MMS Korean not published) ─
  TtsModelSpec(
    id: 'vits-mimic3-ko_KO-kss_low',
    langs: ['ko'],
    engine: SwayTtsEngineKind.vits,
    approxMb: 145,
    bundleUrl: '$_sherpaTts/vits-mimic3-ko_KO-kss_low.tar.bz2',
    modelFile: 'ko_KO-kss_low.onnx',
    tokensFile: 'tokens.txt',
  ),
];

String normalizeLang(String langCode) =>
    langCode.toLowerCase().split(RegExp(r'[-_]')).first;

/// The TTS model serving [langCode], or null when no on-device voice exists
/// (callers then fall back to the cloud / flutter_tts path).
TtsModelSpec? ttsSpecForLang(String langCode) {
  final lc = normalizeLang(langCode);
  for (final s in _specs) {
    if (s.langs.contains(lc)) return s;
  }
  return null;
}

/// Languages that can be spoken fully on-device.
Iterable<String> get supportedTtsLangs => _specs.expand((s) => s.langs);
