import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sherpa_tts_engine.dart';
import 'tts_bundle_downloader.dart';
import 'tts_catalogue.dart';

/// On-device TTS — 100 % local inference via sherpa-onnx `OfflineTts`.
///
/// One runtime, many engines: Kokoro and Piper/VITS are selected per language
/// by [ttsSpecForLang] (see tts_catalogue). The app ships only the runtime; the
/// model bundle for the peer's language is downloaded on first use and cached.
/// STT reads the phone's OWN mic, TTS speaks the PEER's language — so a device
/// installs exactly one voice bundle.
///
/// Usage:
/// ```dart
/// await SpeechService.instance.init();
/// await SpeechService.instance.ensureLanguageInstalled('fr');
/// await SpeechService.instance.speak(
///   text: translatedText,
///   languageCode: 'fr',
///   voice: SpeechService.defaultVoiceFor('fr'),
/// );
/// ```
class SpeechService {
  SpeechService._();
  static final instance = SpeechService._();

  final _downloader = TtsBundleDownloader();
  final _engine = SherpaTtsEngine();

  TtsModelSpec? _loadedSpec;
  String? _loadedLang;
  Future<void>? _loading;

  static const _prefKeySelectedLang = 'speech_selected_lang';
  static const _prefKeySelectedVoice = 'speech_selected_voice';

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Call once at app start. Restores the previously installed language so the
  /// first call is not cold. Idempotent; a no-op on web.
  Future<void> init({void Function(double)? onProgress}) async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString(_prefKeySelectedLang);
      if (lang != null && ttsSpecForLang(lang) != null) {
        await ensureLanguageInstalled(lang, onProgress: onProgress);
      }
    } catch (e) {
      debugPrint('[speech] init error: $e');
    }
  }

  bool get isReady => _engine.isReady;

  // ── Language / voice management ────────────────────────────────────────────

  /// Legacy shim: callers pass this back into [speak]'s `voice` argument, which
  /// is now ignored (the speaker index comes from the language's spec). Kept so
  /// existing call sites compile unchanged.
  static String defaultVoiceFor(String langCode) =>
      ttsSpecForLang(langCode)?.id ?? '';

  /// Downloads (if absent), extracts and configures the model for [langCode].
  ///
  /// Idempotent, and safe to call concurrently: a second call while the first is
  /// still loading awaits the same future instead of building a second engine.
  Future<void> ensureLanguageInstalled(
    String langCode, {
    void Function(double)? onProgress,
  }) {
    if (kIsWeb) return Future.value();
    final lang = normalizeLang(langCode);
    if (_loadedLang == lang && isReady) return Future.value();
    return _loading ??= _load(lang, onProgress).whenComplete(() {
      _loading = null;
    });
  }

  Future<void> _load(String lang, void Function(double)? onProgress) async {
    final spec = ttsSpecForLang(lang);
    if (spec == null) {
      debugPrint('[speech] no on-device voice for "$lang"');
      return;
    }
    try {
      final dir = await _downloader.ensureBundle(spec, onProgress: onProgress);
      String p(String rel) => '${dir.path}/$rel';

      final model = SherpaTtsModel(
        kind: spec.engine,
        model: p(spec.modelFile),
        tokens: p(spec.tokensFile),
        dataDir: spec.dataDir.isEmpty ? '' : p(spec.dataDir),
        voices: spec.voicesFile.isEmpty ? '' : p(spec.voicesFile),
        lexicon: spec.lexiconFiles.map(p).join(','),
        lang: spec.lang,
      );

      await _engine.configure(model);
      _loadedSpec = spec;
      _loadedLang = lang;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeySelectedLang, lang);
      await prefs.setString(_prefKeySelectedVoice, spec.id);

      // The new voice is configured; drop every other bundle so calling peers
      // in different languages doesn't accumulate one bundle per language.
      await TtsBundleDownloader.pruneExcept(spec);
    } catch (e) {
      debugPrint('[speech] load failed for "$lang" (${spec.id}): $e');
    }
  }

  /// Whether [langCode]'s bundle is already on disk (no network needed).
  Future<bool> isLanguageInstalled(String langCode) async {
    if (kIsWeb) return false;
    final spec = ttsSpecForLang(langCode);
    if (spec == null) return false;
    return TtsBundleDownloader.isInstalled(spec);
  }

  // ── Synthesis ──────────────────────────────────────────────────────────────

  /// Synthesise [text] and play it locally. Falls back silently if the engine
  /// for [languageCode] is not ready. [voice] is accepted for API compatibility
  /// but ignored — the speaker index is fixed by the language's spec.
  Future<void> speak({
    required String text,
    required String languageCode,
    String voice = '',
  }) async {
    if (kIsWeb || !isReady) return;
    if (text.trim().isEmpty) return;
    final spec = _loadedSpec;
    if (spec == null) return;
    try {
      await _engine.speak(text, sid: spec.sid, speed: spec.speed);
    } catch (e) {
      debugPrint('[speech] speak error: $e');
    }
  }

  /// Fires when a [speak] utterance finishes playing. [speak] returns at
  /// playback *start*, so this is the only signal for "the speaker is quiet".
  Stream<void> get onPlaybackComplete => _engine.onPlaybackComplete;

  Future<void> stop() async {
    if (kIsWeb) return;
    await _engine.stop();
  }

  Future<void> dispose() async {
    await _engine.dispose();
    _loadedSpec = null;
    _loadedLang = null;
  }

  // ── Preferences restore ────────────────────────────────────────────────────

  Future<String?> savedVoice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeySelectedVoice);
  }

  Future<String?> savedLang() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeySelectedLang);
  }
}
