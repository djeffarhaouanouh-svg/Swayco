import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../../services/debug_overlay.dart';
import 'android_stt_channel.dart';
import 'asr_catalogue.dart' show normalizeLang;
import 'asr_engine.dart';

/// Android's native `SpeechRecognizer` (Google's on-device engine) as a drop-in
/// clip recogniser — the Android twin of [AppleSttEngine].
///
/// A CLIP engine, exactly like [UniversalAsrEngine]: [isStreaming] is false, so
/// the whole [LocalSttMicStreamer] pipeline (VAD segmentation, merge, mute/echo
/// gate, hallucination filters) drives it unchanged — only [transcribe] is
/// different, feeding the clip to the OS recogniser (via a PCM file descriptor,
/// `EXTRA_AUDIO_SOURCE`) instead of sherpa-onnx.
///
/// PRIVACY: on-device recognition is used ONLY when the language's voice model
/// is installed ([AndroidSttChannel.onDeviceLanguages]); [tryLoad] returns null
/// otherwise (under [requireOnDevice]) and [AsrService] then falls back to the
/// bundled Whisper. So the promise that mic audio never leaves the phone is
/// preserved — Google's cloud recognition is never reached.
class AndroidSttEngine extends AsrEngine {
  AndroidSttEngine._(this._locale, this._onDevice);

  /// The BCP-47 locale actually used (e.g. `fr-FR`).
  final String _locale;
  String get locale => _locale;

  /// Whether the resolved locale runs on-device on this phone.
  final bool _onDevice;

  bool _ready = true;

  /// Preferred default locale per primary language tag — same table as Apple.
  static const Map<String, String> _defaultLocale = {
    'en': 'en-US', 'fr': 'fr-FR', 'ja': 'ja-JP', 'zh': 'zh-CN', 'ko': 'ko-KR',
    'es': 'es-ES', 'de': 'de-DE', 'pt': 'pt-BR', 'ar': 'ar-SA', 'ru': 'ru-RU',
    'it': 'it-IT', 'hi': 'hi-IN', 'nl': 'nl-NL', 'pl': 'pl-PL', 'tr': 'tr-TR',
    'uk': 'uk-UA', 'sv': 'sv-SE', 'da': 'da-DK', 'fi': 'fi-FI', 'nb': 'nb-NO',
    'th': 'th-TH', 'id': 'id-ID', 'ms': 'ms-MY', 'vi': 'vi-VN', 'he': 'he-IL',
    'el': 'el-GR', 'hu': 'hu-HU', 'cs': 'cs-CZ', 'sk': 'sk-SK', 'hr': 'hr-HR',
    'ro': 'ro-RO', 'ca': 'ca-ES',
  };

  /// TEST PHASE: allow Google's CLOUD recognition when a language has no
  /// on-device model, so fr/ja can be tried immediately on any phone (and the
  /// emulator, whose on-device model list is empty). Every clip still PREFERS
  /// on-device when the model is present. **Flip to `true` before shipping** —
  /// then a missing model falls back to Whisper instead of sending audio to
  /// Google's servers, restoring the "audio never leaves the phone" guarantee.
  static const bool requireOnDevice = false;

  /// Build an Android engine for [lang]. Returns null when Android STT is
  /// unusable (not Android, API < 33, no on-device recogniser, or — under
  /// [requireOnDevice] — the language is not installed on-device), in which case
  /// the caller falls back to Whisper.
  static Future<AndroidSttEngine?> tryLoad(String lang) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

    final ch = AndroidSttChannel.instance;
    if (!await ch.capable()) {
      DebugOverlay.log(
          'stt Android STT not capable (API<33 or no on-device) — using Whisper');
      return null;
    }

    final resolved = await _resolveLocale(lang);
    if (resolved == null) {
      DebugOverlay.log('stt Android has no recogniser for "$lang" — using Whisper');
      return null;
    }
    final (locale, onDevice) = resolved;
    if (requireOnDevice && !onDevice) {
      DebugOverlay.log('stt Android: "$lang" not on-device — using Whisper');
      return null;
    }
    final mode = onDevice ? 'ON-DEVICE' : 'CLOUD (test)';
    DebugOverlay.log('stt engine=ANDROID locale=$locale $mode for "$lang"');
    // Warm the on-device service/model NOW, while the call is still connecting,
    // so the first phrase pays ~440 ms instead of the ~1.4 s cold-start. Fire and
    // forget — a failed warm-up just means the first phrase is cold, as before.
    unawaited(ch.warmup(locale, requireOnDevice: onDevice));
    return AndroidSttEngine._(locale, onDevice);
  }

  /// Resolve the best locale for [lang] and whether it is installed on-device.
  /// Prefers an on-device locale; otherwise returns a usable cloud locale (test
  /// phase). Null only when no candidate locale exists for the language.
  static Future<(String, bool)?> _resolveLocale(String lang) async {
    final ch = AndroidSttChannel.instance;
    // A route may already carry a region (fr-CA); honour it first.
    final asGiven =
        lang.contains(RegExp(r'[-_]')) ? lang.replaceAll('_', '-') : null;
    final primary = normalizeLang(lang);
    final installed = await ch.onDeviceLanguages();
    final candidates = <String>[
      ?asGiven,
      ?_defaultLocale[primary],
    ];
    // Add every installed locale sharing this primary tag, as further options.
    for (final loc in installed) {
      if (normalizeLang(loc) == primary && !candidates.contains(loc)) {
        candidates.add(loc);
      }
    }
    if (candidates.isEmpty) return null;
    // First choice: a candidate installed on-device. Second choice: the first
    // candidate at all (cloud), so the language is still testable.
    for (final loc in candidates) {
      if (installed.any((i) => normalizeLang(i) == normalizeLang(loc))) {
        return (loc, true);
      }
    }
    return (candidates.first, false);
  }

  @override
  Future<void> load(String modelDir, String lang) async {
    // No-op: this engine is built ready by [tryLoad]. Android manages its own
    // model, there is nothing to load from disk.
  }

  @override
  bool get isReady => _ready;

  @override
  bool get isStreaming => false;

  @override
  Future<String> transcribe(Float32List samples16k) async {
    if (!_ready || samples16k.isEmpty) return '';
    try {
      final res = await AndroidSttChannel.instance.transcribe(
        _locale,
        samples16k,
        requireOnDevice: _onDevice,
      );
      DebugOverlay.log('stt android native=${res.ms}ms '
          '${res.onDevice ? "on-device" : "CLOUD"} → "${res.text}"');
      return res.text.trim();
    } catch (e) {
      DebugOverlay.log('stt Android transcribe error: $e');
      return '';
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
    // Tear down the persistent recogniser held natively for this call.
    unawaited(AndroidSttChannel.instance.release());
  }
}
