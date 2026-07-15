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
    this.gender = '',
    this.isJapanese = false,
    this.lexiconFile = 'lexicon.txt',
    this.openjtalkDictDir = 'open_jtalk_dic_utf_8-1.11',
  });

  /// `'f'` / `'m'` when a language has a matched pair, `''` for a single voice.
  /// The receiver picks by the SPEAKER's account gender, so the peer's voice
  /// sounds like them. A language with only `''` voices ignores gender.
  final String gender;

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

/// One voice from our mirror. Every bundle is repackaged to the same neutral
/// layout (`model.onnx` + `tokens.txt` + phonemiser data under a `v1/` folder),
/// so id is all that changes. [gender] tags one half of a pair; [sid] selects a
/// speaker inside a multi-speaker model (so one bundle can serve both genders).
TtsModelSpec _mirror(
  String lang, {
  String? id,
  String gender = '',
  int sid = 0,
  int mb = 64,
}) {
  final vid = id ?? 'v1-$lang';
  return TtsModelSpec(
    id: vid,
    langs: [lang],
    approxMb: mb,
    bundleUrl: '$_voiceMirror/$vid.tar.bz2',
    modelFile: 'model.onnx',
    gender: gender,
    sid: sid,
  );
}

final List<TtsModelSpec> _specs = <TtsModelSpec>[
  // Every voice comes from our own mirror ([_voiceMirror]) under a neutral name:
  // nothing on the wire, nothing in the bundle, says which voice tech or which
  // speaker. A device downloads only its account language's voice(s).
  //
  // fr / en / de / es are gender-matched: two entries tagged 'f'/'m', so the
  // peer's line comes out in a voice of the peer's gender. Both halves are
  // fetched at boot (the "2 voices max" a device holds). es uses ONE
  // multi-speaker bundle — sid 0 is the man, sid 1 the woman. Every other
  // language has a single voice and ignores gender. ja is single by nature: a
  // quality Japanese voice needs its reading engine, and that model is one voice.

  // fr — siwis (f) / tom (m)
  _mirror('fr', gender: 'f'),
  _mirror('fr', id: 'v1-fr-m', gender: 'm'),
  // en — lessac (f) / ryan (m), both premium 'high'
  _mirror('en', gender: 'f', mb: 110),
  _mirror('en', id: 'v1-en-m', gender: 'm', mb: 110),
  // de — thorsten (m) / kerstin (f)
  _mirror('de', gender: 'm', mb: 110),
  _mirror('de', id: 'v1-de-f', gender: 'f'),
  // es — one multi-speaker bundle: sid 0 man, sid 1 woman
  _mirror('es', id: 'v1-es-f', gender: 'm', sid: 0),
  _mirror('es', id: 'v1-es-f', gender: 'f', sid: 1),

  // Single-voice languages (no gender pair).
  _mirror('pt'),
  _mirror('it'),
  _mirror('nl'),
  _mirror('pl'),
  _mirror('sv'),
  _mirror('tr'),
  _mirror('ru'),
  _mirror('uk'),
  _mirror('ar'),
  _mirror('hi'),
  _mirror('zh'),
  _mirror('ko', mb: 63),

  // Japanese → dedicated on-device engine: native reading frontend + phonemizer
  // + an external-tokens path, on the app's single ORT. The bundle carries the
  // fp16 model, tokens, lexicon and the reading dictionary. ~110 MB, one voice.
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

/// The voice serving [langCode] for a speaker of [gender] (`'f'`/`'m'`/`''`).
///
/// When the language has a matched pair, the entry whose [TtsModelSpec.gender]
/// equals [gender] wins; otherwise (unknown gender, or a language with a single
/// voice) the first entry for the language is used. Never null-picks across a
/// gender: a missing pair falls back to the language's default voice, never to
/// another language.
TtsModelSpec? ttsSpecForLang(String langCode, {String gender = ''}) {
  final lc = normalizeLang(langCode);
  final forLang = _specs.where((s) => s.langs.contains(lc)).toList();
  if (forLang.isEmpty) return null;
  if (gender.isNotEmpty) {
    for (final s in forLang) {
      if (s.gender == gender) return s;
    }
  }
  return forLang.first;
}

/// Every voice for [langCode] — up to two (a gender pair). Used to download
/// both at once so either speaker's voice is ready before the first call.
List<TtsModelSpec> ttsSpecsForLang(String langCode) {
  final lc = normalizeLang(langCode);
  return _specs.where((s) => s.langs.contains(lc)).toList();
}

/// Languages that can be spoken fully on-device.
Iterable<String> get supportedTtsLangs => _specs.expand((s) => s.langs);
