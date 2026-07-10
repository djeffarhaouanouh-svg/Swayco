import 'package:flutter/foundation.dart';

import '../../services/debug_overlay.dart';
import 'asr_catalogue.dart';
import 'asr_engine.dart';
import 'asr_model_downloader.dart';

/// On-device speech-to-text — 100 % local inference, no audio leaves the phone.
///
/// Deliberately shaped like [SpeechService]: the app ships the engines, the
/// model for the user's own language is downloaded on first use and cached.
/// STT reads this phone's OWN outgoing mic, so exactly one language is ever
/// installed here — the same one the local TTS engine installs a voice for.
///
/// ```dart
/// await AsrService.instance.ensureLanguageInstalled('fr');
/// final text = await AsrService.instance.transcribe(samples16k);
/// ```
class AsrService {
  AsrService._();
  static final instance = AsrService._();

  final _downloader = AsrModelDownloader();

  AsrEngine? _engine;
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
    return AsrModelDownloader.isInstalled(spec);
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
      DebugOverlay.log('stt NO on-device model for "$lang"');
      return;
    }
    DebugOverlay.log(
        'stt load lang=$lang engine=${spec.kind.name} model=${spec.id} (~${spec.approxMb} MB)');
    try {
      final installed = await AsrModelDownloader.isInstalled(spec);
      DebugOverlay.log('stt model already on disk: $installed');

      // Progress is logged in decade steps: a per-chunk line would drown the
      // overlay's 120-line buffer before the download finished.
      var lastPct = -1;
      final dir = await _downloader.ensureModel(spec, onProgress: (p) {
        onProgress?.call(p);
        final pct = (p * 10).floor() * 10;
        if (pct != lastPct) {
          lastPct = pct;
          DebugOverlay.log('stt download ${spec.id} $pct%');
        }
      });
      DebugOverlay.log('stt model dir=${dir.path}');

      // Swap only once the new engine is up, so a failed load leaves the
      // previous language working rather than muting the call.
      final engine = createAsrEngine(spec.kind);
      await engine.load(dir.path, lang);
      DebugOverlay.log(
          'stt engine loaded ready=${engine.isReady} streaming=${engine.isStreaming}');

      final old = _engine;
      _engine = engine;
      _loadedLang = lang;
      await old?.dispose();

      // Now that the new model is live and the old engine is disposed, drop
      // every other language's files so switching languages doesn't accumulate
      // one model directory per language ever used.
      await AsrModelDownloader.pruneExcept(spec);
    } catch (e) {
      DebugOverlay.log('stt LOAD FAILED "$lang" (${spec.id}): $e');
      debugPrint('[stt] load failed for "$lang" (${spec.id}): $e');
    }
  }

  /// True when the loaded engine consumes frames and endpoints utterances
  /// itself (lattice). False for a clip engine the caller must segment (neural).
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
