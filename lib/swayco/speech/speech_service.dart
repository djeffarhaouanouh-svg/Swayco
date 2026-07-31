import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Via the web-safe facades: the engines are dart:ffi and the downloader is
// dart:io, neither of which exists on the web. The kIsWeb guards below are not
// enough on their own — an import is resolved at compile time.
import 'tts_downloader.dart';
import 'tts_engines.dart';
import 'tts_catalogue.dart';

/// On-device TTS — 100 % local inference via the runtime `OfflineTts`.
///
/// One runtime, many engines: a multilingual model and neural/neural are selected per language
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
  final _engine = NeuralTtsEngine();
  final _jaEngine = JaTtsEngine();

  /// Whether the currently loaded voice is Japanese (→ [_jaEngine]).
  bool _useJa = false;

  TtsModelSpec? _loadedSpec;
  String? _loadedLang;
  Future<void>? _loading;

  /// Gender of the currently loaded voice (`'f'`/`'m'`/`''`). Tracks which half
  /// of a pair is live so [isLoadedFor] can tell "wrong gender, reload" from
  /// "already right".
  String get _loadedGender => _loadedSpec?.gender ?? '';

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

  /// La voix embarquée est COUPÉE — tout passe par flutter_tts.
  ///
  /// Elle marchait, et vite : 40 ms entre la demande et le premier son une fois
  /// passée en palier medium. Ce n'est pas la vitesse qui l'a fait tomber, c'est
  /// qu'elle n'apportait pas assez pour justifier ce qu'elle coûte — 67 MB par
  /// voix à télécharger, une étape de synthèse, et un second moteur audio à
  /// tenir. La voix du système fait le travail, et une conversation entière s'y
  /// est déroulée sans qu'on entende la différence.
  ///
  /// Coupé ICI plutôt qu'au point d'appel : les téléchargements partent du
  /// démarrage de l'app, de l'onboarding et de l'écran d'appel. Une seule porte
  /// fermée vaut mieux que sept, et personne ne peut la contourner par
  /// inadvertance.
  ///
  /// Repasser à `true` rallume tout — moteurs, bundles medium, synthèse
  /// anticipée. Rien n'a été supprimé, seulement débranché.
  static const bool enabled = false;

  static const _prefKeySelectedLang = 'speech_selected_lang';
  static const _prefKeySelectedVoice = 'speech_selected_voice';

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Call once at app start. Restores the previously installed language so the
  /// first call is not cold. Idempotent; a no-op on web.
  Future<void> init({void Function(double)? onProgress}) async {
    if (kIsWeb || !enabled) return;
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
  bool isLoadedFor(String langCode, {String gender = ''}) {
    if (!isReady || _loadedLang != normalizeLang(langCode)) return false;
    // A language with no gender pair speaks with its single voice regardless of
    // who is talking. A paired language must have the matching half loaded — but
    // an unknown speaker gender ('x' or '') takes whatever is loaded rather than
    // forcing a reload to nothing.
    if (gender.isEmpty || _loadedGender.isEmpty) return true;
    return _loadedGender == gender;
  }

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
    String gender = '',
    void Function(double)? onProgress,
  }) {
    if (kIsWeb || !enabled) return Future.value();
    final lang = normalizeLang(langCode);
    // Already speaking this language in a voice that matches → nothing to do.
    if (isLoadedFor(lang, gender: gender)) return Future.value();
    return _loading ??= _load(lang, gender, onProgress).whenComplete(() {
      _loading = null;
    });
  }

  /// Fetch every voice for [langCode] (both halves of a pair) onto disk without
  /// loading any. Called at boot so the peer's matching voice is already local
  /// when a call starts — the only thing left to do then is configure it, which
  /// is fast. Fire-and-forget; failures fall back to the OS voice later.
  Future<void> prefetchLanguage(String langCode) async {
    if (kIsWeb || !enabled) return;
    for (final spec in ttsSpecsForLang(langCode)) {
      try {
        await _downloader.ensureBundle(spec);
      } catch (e) {
        debugPrint('[speech] prefetch ${spec.id} failed: $e');
      }
    }
  }

  Future<void> _load(
    String lang,
    String gender,
    void Function(double)? onProgress,
  ) async {
    final spec = ttsSpecForLang(lang, gender: gender);
    if (spec == null) {
      debugPrint('[speech] no on-device voice for "$lang"');
      return;
    }
    try {
      _wirePlayback();
      final dir = await _downloader.ensureBundle(spec, onProgress: onProgress);
      String p(String rel) => '${dir.path}/$rel';

      if (spec.isJapanese) {
        // Native the reading frontend reading + phonemizer + an external-tokens path.
        await _jaEngine.configure(JaTtsModel(
          model: p(spec.modelFile),
          tokens: p(spec.tokensFile),
          lexicon: p(spec.lexiconFile),
          dictDir: p(spec.openjtalkDictDir),
        ));
        _useJa = true;
      } else {
        // All other catalogue entries are neural (neural): model + tokens +
        // the phonemiser data are enough.
        await _engine.configure(NeuralTtsModel(
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

      // Drop bundles for other languages, but KEEP both halves of this
      // language's gender pair: switching to speak the other gender mid-session
      // must not trigger a re-download.
      await TtsBundleDownloader.pruneExcept(
        ttsSpecsForLang(lang).map((s) => s.id).toSet(),
      );
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

  /// Synthesise [text] to a WAV on disk and return its path — nothing plays.
  /// Null when no engine is ready or there was nothing to say.
  ///
  /// Split out from [speak] so a call can synthesise the NEXT sentence while
  /// the current one is still being heard. On this hardware synthesis is the
  /// slow half by a wide margin, so overlapping it with playback — and with
  /// the wait for the peer to stop talking — is most of what there is to win.
  Future<String?> synthesise({
    required String text,
    required String languageCode,
  }) async {
    if (kIsWeb || !isReady) return null;
    if (text.trim().isEmpty) return null;
    final spec = _loadedSpec;
    if (spec == null) return null;
    try {
      return _useJa
          ? await _jaEngine.synthesiseToFile(text,
              sid: spec.sid, speed: spec.speed)
          : await _engine.synthesiseToFile(text,
              sid: spec.sid, speed: spec.speed);
    } catch (e) {
      debugPrint('[speech] synthesise error: $e');
      return null;
    }
  }

  /// Play a WAV [synthesise] produced. Returns at playback *start*; the end is
  /// announced on [onPlaybackComplete].
  Future<void> playFile(String path) async {
    if (kIsWeb) return;
    try {
      if (_useJa) {
        await _jaEngine.playFile(path);
      } else {
        await _engine.playFile(path);
      }
    } catch (e) {
      debugPrint('[speech] playFile error: $e');
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
