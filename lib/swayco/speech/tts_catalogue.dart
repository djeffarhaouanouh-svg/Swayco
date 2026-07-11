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
/// ⚠️ Japanese has NO on-device voice here, on purpose. sherpa cannot phonemise
/// Japanese: it has no word segmenter (mecab) and no kanji→reading, so it splits
/// text character-by-character and crashes on kanji — verified in a CLI test of
/// the melo-onnx lexicon model. Every quality ja model (piper-plus, VOICEVOX,
/// Style-BERT-VITS2, MeloTTS) needs openjtalk/mecab, which sherpa doesn't have.
/// So ja is simply absent from this catalogue → `ttsSpecForLang('ja')` is null →
/// call_screen falls back to the OS native voice (iOS AVSpeechSynthesizer, which
/// handles Japanese well). A dedicated openjtalk-based ja engine is a post-launch
/// project — see project memory.
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

  // Korean → mimic3 (also a plain VITS/espeak model, already sherpa-ready).
  const TtsModelSpec(
    id: _mimic3Ko,
    langs: ['ko'],
    approxMb: 63,
    bundleUrl: '$_sherpaTts/$_mimic3Ko.tar.bz2',
    modelFile: 'ko_KO-kss_low.onnx',
  ),

  // Japanese → intentionally absent (OS native voice fallback). See class doc.
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
