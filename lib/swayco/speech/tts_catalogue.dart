/// Which on-device voice serves which language.
///
/// Shaped like [asr_catalogue]: the app ships only the neural runtime; the voice
/// bundle for the user's account language is downloaded on first use and cached.
/// A device speaks one language, so it downloads one bundle, and `pruneExcept`
/// deletes any previous one.
///
/// Every entry is one lightweight neural voice per language (~60 MB), each
/// `.tar.bz2` already carrying its own phonemiser data. A single multilingual
/// voice was dropped — too heavy (300+ MB) for a one-language-per-device app.
///
/// Japanese is the exception: the general phonemiser can't read it (kanji have
/// no fixed pronunciation). It has its own on-device engine ([JaTtsEngine]):
/// native reading frontend + a Dart phonemizer + an external-tokens path, all on
/// the app's single ONNX Runtime. Its catalogue entry carries `isJapanese = true`
/// so [SpeechService] routes it there instead of the general voice path.
library;

/// Our mirror — neutral bundle names, nothing on the wire says which voice
/// tech or which speaker. The account language downloads from here.
const _voiceMirror = 'https://huggingface.co/djeffar/swayco-tts/resolve/main';

/// The un-mirrored upstream, still used by every language we have NOT copied to
/// [_voiceMirror] yet. A first launch in one of those languages announces the
/// voice on the network — mirror it (like `v1-fr`) to close that, one at a time.
const _upstreamHost =
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

  /// Japanese is the one language off the general phoneme path: it uses
  /// [JaTtsEngine] (native reading frontend + phonemizer + an external-tokens
  /// path) instead of the general voice engine. When true, [lexiconFile] and
  /// [openjtalkDictDir] are used and [dataDir] is ignored.
  final bool isJapanese;
  final String lexiconFile;
  final String openjtalkDictDir;
}

/// An upstream voice bundle: id is the release asset name, the model file inside
/// is `<voice>.onnx`. Used for every language not yet on [_voiceMirror].
TtsModelSpec _upstreamVoice(String voice, List<String> langs, {int mb = 64}) {
  final id = 'vits-piper-$voice';
  return TtsModelSpec(
    id: id,
    langs: langs,
    approxMb: mb,
    bundleUrl: '$_upstreamHost/$id.tar.bz2',
    modelFile: '$voice.onnx',
  );
}

const _koVoice = 'vits-mimic3-ko_KO-kss_low';

final List<TtsModelSpec> _specs = <TtsModelSpec>[
  // Premium tier everywhere the upstream has one; the rest stay at their best
  // available tier. Every entry still on [_upstreamHost] names its voice on the
  // network at first launch — mirror it to [_voiceMirror] under a neutral name
  // to close that, as fr and ja already are.
  //
  // fr and ja (the launch markets) come from our own mirror: nothing on the
  // wire, nothing in the bundle, says which voice or which tech. The rest are
  // premium-by-tier but not yet hidden.
  const TtsModelSpec(
    id: 'v1-fr',
    langs: ['fr'],
    approxMb: 64,
    bundleUrl: '$_voiceMirror/v1-fr.tar.bz2',
    modelFile: 'model.onnx',
  ),
  _upstreamVoice('en_US-lessac-high', ['en'], mb: 110),
  _upstreamVoice('es_ES-davefx-medium', ['es']),
  _upstreamVoice('pt_BR-faber-medium', ['pt']),
  _upstreamVoice('it_IT-paola-medium', ['it']),
  _upstreamVoice('de_DE-thorsten-high', ['de'], mb: 110),
  _upstreamVoice('nl_BE-rdh-medium', ['nl']),
  _upstreamVoice('pl_PL-darkman-medium', ['pl']),
  _upstreamVoice('sv_SE-nst-medium', ['sv']),
  _upstreamVoice('tr_TR-dfki-medium', ['tr']),
  _upstreamVoice('ru_RU-dmitri-medium', ['ru']),
  _upstreamVoice('uk_UA-ukrainian_tts-medium', ['uk']),
  _upstreamVoice('ar_JO-kareem-medium', ['ar']),
  _upstreamVoice('hi_IN-pratham-medium', ['hi']),
  _upstreamVoice('zh_CN-huayan-medium', ['zh']),

  // Korean → same general voice engine (still upstream, not yet mirrored).
  const TtsModelSpec(
    id: _koVoice,
    langs: ['ko'],
    approxMb: 63,
    bundleUrl: '$_upstreamHost/$_koVoice.tar.bz2',
    modelFile: 'ko_KO-kss_low.onnx',
  ),

  // Japanese → dedicated on-device engine: native reading frontend + phonemizer
  // + an external-tokens path, on the app's single ORT. From our mirror under a
  // neutral name; the bundle carries the fp16 model, tokens, lexicon and the
  // reading dictionary. ~110 MB.
  const TtsModelSpec(
    id: 'v1-ja',
    langs: ['ja'],
    approxMb: 110,
    bundleUrl: '$_voiceMirror/v1-ja.tar.bz2',
    modelFile: 'model.fp16.onnx',
    isJapanese: true,
  ),
];


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
