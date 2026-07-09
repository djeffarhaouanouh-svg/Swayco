import 'package:flutter/foundation.dart';

import 'stt_catalogue.dart';
import 'stt_engine.dart';
import 'stt_model_downloader.dart';

/// On-device speech-to-text — 100 % local inference, no audio leaves the phone.
///
/// Deliberately shaped like [KokoroService]: the app ships the engines, the
/// model for the user's own language is downloaded on first use and cached.
/// STT reads this phone's OWN outgoing mic, so exactly one language is ever
/// installed here — the same one Kokoro installs a voice for.
///
/// ```dart
/// await SttService.instance.ensureLanguageInstalled('fr');
/// final text = await SttService.instance.transcribe(samples16k);
/// ```
class SttService {
  SttService._();
  static final instance = SttService._();

  final _downloader = SttModelDownloader();

  SttEngine? _engine;
  String? _loadedLang;
  Future<void>? _loading;

  bool get isReady => _engine?.isReady ?? false;

  /// The language currently loaded, or null when no model is resident.
  String? get loadedLang => _loadedLang;

  static bool supportsLang(String langCode) =>
      specForLang(langCode) != null;

  /// Whether [langCode]'s model is already on disk (no network needed).
  static Future<bool> isLanguageInstalled(String langCode) async {
    if (kIsWeb) return false;
    final spec = specForLang(langCode);
    if (spec == null) return false;
    return SttModelDownloader.isInstalled(spec);
  }

  /// Downloads (if absent) and loads the model for [langCode].
  ///
  /// Idempotent, and safe to call concurrently: a second call while the first
  /// is still loading awaits the same future instead of opening a second ONNX
  /// session on the same files.
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
    final spec = specForLang(lang);
    if (spec == null) {
      debugPrint('[stt] no on-device model for "$lang"');
      return;
    }
    try {
      final dir = await _downloader.ensureModel(spec, onProgress: onProgress);

      // Swap only once the new engine is up, so a failed load leaves the
      // previous language working rather than muting the call.
      final engine = createSttEngine(spec.kind);
      await engine.load(dir.path, lang);

      final old = _engine;
      _engine = engine;
      _loadedLang = lang;
      await old?.dispose();
    } catch (e) {
      debugPrint('[stt] load failed for "$lang" (${spec.id}): $e');
    }
  }

  /// True when the loaded engine consumes frames and endpoints utterances
  /// itself (Vosk). False for a clip engine the caller must segment (Moonshine).
  bool get isStreaming => _engine?.isStreaming ?? false;

  /// Feed one frame to a streaming engine. 16 kHz mono, samples in [-1, 1].
  Future<SttChunk> acceptFrame(Float32List samples16k) async {
    final engine = _engine;
    if (kIsWeb || engine == null || !engine.isReady) return SttChunk.empty;
    return engine.acceptFrame(samples16k);
  }

  /// Close the utterance in progress and return it.
  Future<String> flush() async {
    final engine = _engine;
    if (kIsWeb || engine == null || !engine.isReady) return '';
    return engine.flush();
  }

  /// Drop decoder state for audio we deliberately discarded.
  Future<void> reset() async {
    final engine = _engine;
    if (kIsWeb || engine == null || !engine.isReady) return;
    return engine.reset();
  }

  /// Transcribe one VAD-clipped utterance. 16 kHz mono, samples in [-1, 1].
  /// Returns '' when the model isn't ready or nothing was recognised.
  Future<String> transcribe(Float32List samples16k) async {
    final engine = _engine;
    if (kIsWeb || engine == null || !engine.isReady) return '';
    return engine.transcribe(samples16k);
  }

  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    _loadedLang = null;
    await engine?.dispose();
  }
}
