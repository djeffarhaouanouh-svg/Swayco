import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ja_tts_engine.dart';
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
  final _jaEngine = JaTtsEngine();

  /// Whether the currently loaded voice is Japanese (→ [_jaEngine]).
  bool _useJa = false;

  TtsModelSpec? _loadedSpec;
  String? _loadedLang;
  Future<void>? _loading;

  /// Playback-complete events, merged from both engines.
  ///
  /// The in-call half-duplex gate subscribes to this to reopen the mic as soon
  /// as an utterance stops playing (see `call_screen._playWithLocalTts`). Losing
  /// an event does not open the mic early — the gate's safety timer is the floor
  /// — but it holds the mic shut for the whole 15 s window, so the wiring must
  /// be as unconditional as the old direct `_engine.onPlaybackComplete` was:
  ///   * wired on first *subscription*, not inside `_load`, so it is live even
  ///     if no voice ever loads;
  ///   * both engines forwarded unconditionally (never filtered on [_useJa] —
  ///     only one engine is ever configured, so the idle one never fires, and a
  ///     language switch mid-utterance must not swallow the event).
  final _playbackComplete = StreamController<void>.broadcast();
  bool _playbackWired = false;

  void _wirePlayback() {
    if (_playbackWired) return;
    _playbackWired = true;
    _engine.onPlaybackComplete.listen((_) => _playbackComplete.add(null));
    _jaEngine.onPlaybackComplete.listen((_) => _playbackComplete.add(null));
  }

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

  bool get isReady => _useJa ? _jaEngine.isReady : _engine.isReady;

  /// Whether the engine is loaded *and* loaded for [langCode] — i.e. this voice
  /// can speak right now, with no download.
  ///
  /// The in-call language button lets the user hear the peer in a language other
  /// than their account one. That pick must speak immediately, so it goes to the
  /// device's own OS voice instead of pulling a 60 MB bundle mid-call; only the
  /// account language (installed at boot) is served from here.
  bool isLoadedFor(String langCode) =>
      isReady && _loadedLang == normalizeLang(langCode);

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
      _wirePlayback();
      final dir = await _downloader.ensureBundle(spec, onProgress: onProgress);
      String p(String rel) => '${dir.path}/$rel';

      if (spec.isJapanese) {
        // Native OpenJTalk reading + phonemizer + patched sherpa external-tokens.
        await _jaEngine.configure(JaTtsModel(
          model: p(spec.modelFile),
          tokens: p(spec.tokensFile),
          lexicon: p(spec.lexiconFile),
          dictDir: p(spec.openjtalkDictDir),
        ));
        _useJa = true;
      } else {
        // All other catalogue entries are VITS (Piper/mimic3): model + tokens +
        // espeak data are enough.
        await _engine.configure(SherpaTtsModel(
          model: p(spec.modelFile),
          tokens: p(spec.tokensFile),
          dataDir: spec.dataDir.isEmpty ? '' : p(spec.dataDir),
        ));
        _useJa = false;
      }
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
      if (_useJa) {
        await _jaEngine.speak(text, sid: spec.sid, speed: spec.speed);
      } else {
        await _engine.speak(text, sid: spec.sid, speed: spec.speed);
      }
    } catch (e) {
      debugPrint('[speech] speak error: $e');
    }
  }

  /// Fires when a [speak] utterance finishes playing. [speak] returns at
  /// playback *start*, so this is the only signal for "the speaker is quiet".
  /// Wiring happens here, on first subscription, so the stream is live even when
  /// no voice has been loaded (the half-duplex gate subscribes before speaking).
  Stream<void> get onPlaybackComplete {
    _wirePlayback();
    return _playbackComplete.stream;
  }

  Future<void> stop() async {
    if (kIsWeb) return;
    await _engine.stop();
    await _jaEngine.stop();
  }

  Future<void> dispose() async {
    await _engine.dispose();
    await _jaEngine.dispose();
    await _playbackComplete.close();
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
