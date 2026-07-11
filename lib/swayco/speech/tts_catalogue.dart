/// Which on-device TTS model serves which language.
///
/// Shaped like [asr_catalogue]: the app ships only the sherpa-onnx runtime; the
/// model bundle for the user's account language is downloaded on first use and
/// cached. A device speaks one language, so it downloads one bundle, and
/// `pruneExcept` deletes any previous one.
///
/// **All VITS** (Piper + mimic3 are both plain VITS models — same engine path):
/// one lightweight voice per language (~60 MB), each `.tar.bz2` already carrying
/// its own `espeak-ng-data/`. Kokoro was dropped — its multilingual model is
/// 326 MB (140 MB even int8), far too heavy for a one-language-per-device app.
///
/// Every bundle URL below was verified to exist (HTTP 200) and every Piper
/// bundle follows the confirmed layout `<voice>.onnx` + `tokens.txt` +
/// `espeak-ng-data/`.
///
/// Japanese is the exception: sherpa cannot phonemise it (no mecab / kanji
/// reading — it char-splits and crashes on kanji). It has its own on-device
/// engine ([JaTtsEngine]): native OpenJTalk reading + a Dart phonemizer + a
/// patched sherpa "external tokens" path, all on the app's single ONNX Runtime.
/// Its catalogue entry carries `isJapanese = true` so [SpeechService] routes it
/// to that engine instead of the stock sherpa VITS path. See
/// `docs/ja_tts_engine_plan.md`.
library;

const _sherpaTts =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

class TtsModelSpec {
  const TtsModelSpec({
    required this.id,
    required this.langs,
    required this.approxMb,
    required this.bundleUrl,
    required this.modelFile,
    this.tokensFile = 'tokens.txt',
    this.dataDir = 'espeak-ng-data',
    this.sid = 0,
    this.speed = 1.0,
    this.isJapanese = false,
    this.lexiconFile = 'lexicon.txt',
    this.openjtalkDictDir = 'open_jtalk_dic_utf_8-1.11',
  });

  /// Directory name under `<appSupport>/tts/`.
  final String id;
  final List<String> langs;
  final int approxMb;

  /// A single `.tar.bz2` whose one top-level folder is flattened into the id dir.
  final String bundleUrl;

  // Paths below are relative to the flattened install dir.
  final String modelFile;
  final String tokensFile;
  final String dataDir;

  final int sid;
  final double speed;

  /// Japanese is the one language not on the sherpa g2p path: it uses
  /// [JaTtsEngine] (native OpenJTalk reading + phonemizer + patched sherpa
  /// external-tokens) instead of the stock sherpa VITS engine. When true,
  /// [lexiconFile] and [openjtalkDictDir] are used and [dataDir] is ignored.
  final bool isJapanese;
  final String lexiconFile;
  final String openjtalkDictDir;
}

/// A sherpa Piper bundle: id is the release asset name, the model file inside is
/// `<voice>.onnx` where `<voice>` is the id minus the `vits-piper-` prefix.
TtsModelSpec _piper(String voice, List<String> langs, {int mb = 64}) {
  final id = 'vits-piper-$voice';
  return TtsModelSpec(
    id: id,
    langs: langs,
    approxMb: mb,
    bundleUrl: '$_sherpaTts/$id.tar.bz2',
    modelFile: '$voice.onnx',
  );
}

/// A sherpa MMS bundle (Meta MMS-TTS, converted by sherpa): still plain VITS, so
/// the same engine — but its frontend is a *character* frontend over the native
/// script, not espeak-ng. There is therefore no `espeak-ng-data/` in the bundle
/// and `dataDir` must stay empty (SpeechService passes '' through untouched).
///
/// Only used where no Piper voice exists. Bigger (~103 MB, fp32 only — no int8 /
/// fp16 variants are published) and lower quality than Piper.
///
/// sherpa refuses MMS models flagged `is_uroman` (it has no romaniser), so the
/// only usable ones are those whose vocab is over their own script. All the
/// languages here are in that set.
TtsModelSpec _mms(String iso3, List<String> langs, {int mb = 103}) {
  final id = 'vits-mms-$iso3';
  return TtsModelSpec(
    id: id,
    langs: langs,
    approxMb: mb,
    bundleUrl: '$_sherpaTts/$id.tar.bz2',
    modelFile: 'model.onnx',
    dataDir: '',
  );
}

const _mimic3Ko = 'vits-mimic3-ko_KO-kss_low';

final List<TtsModelSpec> _specs = <TtsModelSpec>[
  _piper('en_US-amy-medium', ['en']),
  _piper('fr_FR-siwis-medium', ['fr']),
  _piper('es_ES-davefx-medium', ['es']),
  _piper('pt_BR-faber-medium', ['pt']),
  _piper('it_IT-paola-medium', ['it']),
  _piper('de_DE-thorsten-medium', ['de']),
  _piper('nl_BE-rdh-medium', ['nl']),
  _piper('pl_PL-darkman-medium', ['pl']),
  _piper('sv_SE-nst-medium', ['sv']),
  _piper('tr_TR-dfki-medium', ['tr']),
  _piper('ru_RU-dmitri-medium', ['ru']),
  _piper('uk_UA-ukrainian_tts-medium', ['uk']),
  _piper('ar_JO-kareem-medium', ['ar']),
  _piper('hi_IN-pratham-medium', ['hi']),
  _piper('zh_CN-huayan-medium', ['zh']),

  // Thai → MMS: no Piper voice exists. Thai is unspaced and the MMS frontend is
  // per-character over Thai script, so no word segmenter is needed.
  _mms('tha', ['th']),

  // Korean → mimic3 (also a plain VITS/espeak model, already sherpa-ready).
  const TtsModelSpec(
    id: _mimic3Ko,
    langs: ['ko'],
    approxMb: 63,
    bundleUrl: '$_sherpaTts/$_mimic3Ko.tar.bz2',
    modelFile: 'ko_KO-kss_low.onnx',
  ),

  // Japanese → dedicated on-device engine (see docs/ja_tts_engine_plan.md):
  // native OpenJTalk reading + phonemizer + patched sherpa external-tokens, on
  // the app's single ORT. Bundle carries the fp16 model, tokens.txt, lexicon.txt
  // and the OpenJTalk dictionary. ~110 MB (model ~87 MB + dict ~23 MB).
  const TtsModelSpec(
    id: 'ja-melo-openjtalk',
    langs: ['ja'],
    approxMb: 110,
    bundleUrl: '$_djeffarTts/ja-melo-openjtalk.tar.bz2',
    modelFile: 'model.fp16.onnx',
    isJapanese: true,
  ),
];

/// Re-hosted bundles under the project's own Hugging Face (currently just the
/// Japanese voice, which is assembled from the MeloTTS-ONNX export + OpenJTalk
/// dict rather than a sherpa release).
const _djeffarTts =
    'https://huggingface.co/djeffar/swayco-tts/resolve/main';

String normalizeLang(String langCode) =>
    langCode.toLowerCase().split(RegExp(r'[-_]')).first;

/// The TTS model serving [langCode], or null when no on-device voice exists.
TtsModelSpec? ttsSpecForLang(String langCode) {
  final lc = normalizeLang(langCode);
  for (final s in _specs) {
    if (s.langs.contains(lc)) return s;
  }
  return null;
}

/// Languages that can be spoken fully on-device.
Iterable<String> get supportedTtsLangs => _specs.expand((s) => s.langs);
