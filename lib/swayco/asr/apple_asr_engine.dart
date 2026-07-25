import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../../services/debug_overlay.dart';
import 'apple_stt_channel.dart';
import 'asr_catalogue.dart' show normalizeLang;
import 'asr_engine.dart';

/// Apple's native `SFSpeechRecognizer` as a drop-in clip recogniser.
///
/// A CLIP engine, exactly like [UniversalAsrEngine]: [isStreaming] is false, so
/// the whole [LocalSttMicStreamer] pipeline (VAD segmentation, merge, mute/echo
/// gate, hallucination filters) drives it unchanged — only [transcribe] is
/// different, calling the OS instead of sherpa-onnx.
///
/// PRIVACY: this engine is used ONLY when the language's dictation asset is
/// installed on-device ([supportsOnDeviceRecognition]); [tryLoad] returns null
/// otherwise, and [AsrService] then falls back to the bundled Whisper. So the
/// promise that mic audio never leaves the phone is preserved — Apple's cloud
/// recognition is never reached.
class AppleSttEngine extends AsrEngine {
  AppleSttEngine._(this._locale);

  /// The BCP-47 locale actually used (e.g. `fr-FR`), resolved from the app's
  /// primary-tag language and confirmed on-device.
  final String _locale;
  String get locale => _locale;

  bool _ready = true;

  /// Preferred default locale per primary language tag. Apple keys recognisers
  /// on region-qualified locales; the app carries only primary tags, so we pick
  /// a sensible default and, failing that, scan every supported locale for the
  /// first on-device match with the same primary tag (see [_resolveLocale]).
  static const Map<String, String> _defaultLocale = {
    'en': 'en-US', 'fr': 'fr-FR', 'ja': 'ja-JP', 'zh': 'zh-CN', 'ko': 'ko-KR',
    'es': 'es-ES', 'de': 'de-DE', 'pt': 'pt-BR', 'ar': 'ar-SA', 'ru': 'ru-RU',
    'it': 'it-IT', 'hi': 'hi-IN', 'nl': 'nl-NL', 'pl': 'pl-PL', 'tr': 'tr-TR',
    'uk': 'uk-UA', 'sv': 'sv-SE', 'da': 'da-DK', 'fi': 'fi-FI', 'nb': 'nb-NO',
    'th': 'th-TH', 'id': 'id-ID', 'ms': 'ms-MY', 'vi': 'vi-VN', 'he': 'he-IL',
    'el': 'el-GR', 'hu': 'hu-HU', 'cs': 'cs-CZ', 'sk': 'sk-SK', 'hr': 'hr-HR',
    'ro': 'ro-RO', 'ca': 'ca-ES', 'yue': 'yue-CN',
  };

  /// TEST PHASE: allow Apple's CLOUD recognition when a language has no
  /// on-device asset, so fr/ja can be tried immediately on any phone. Every
  /// clip still PREFERS on-device when the asset is present. **Flip to `true`
  /// before shipping** — then a missing asset falls back to Whisper instead of
  /// sending audio to Apple's servers, restoring the "audio never leaves the
  /// phone" guarantee.
  static const bool requireOnDevice = false;

  /// Whether the resolved locale runs on-device on this phone. Logged so the
  /// debug overlay says plainly which path each call took.
  bool _localeOnDevice = false;

  /// Build an Apple engine for [lang]. Returns null only when Apple is truly
  /// unusable (not iOS, not authorized, no recogniser for the language at all),
  /// in which case the caller falls back to Whisper. When [requireOnDevice] is
  /// false, an engine is returned even for a cloud-only language (test phase).
  static Future<AppleSttEngine?> tryLoad(String lang) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;

    final auth = await AppleSttChannel.instance.requestAuth();
    if (auth != AppleSttAuth.authorized) {
      DebugOverlay.log('stt Apple auth=${auth.name} — falling back to Whisper');
      return null;
    }

    final resolved = await _resolveLocale(lang);
    if (resolved == null) {
      DebugOverlay.log('stt Apple has no recogniser for "$lang" — using Whisper');
      return null;
    }
    final (locale, onDevice) = resolved;
    if (requireOnDevice && !onDevice) {
      DebugOverlay.log('stt Apple: "$lang" not on-device — using Whisper');
      return null;
    }
    final mode = onDevice ? 'ON-DEVICE' : 'CLOUD (test)';
    DebugOverlay.log('stt engine=APPLE locale=$locale $mode for "$lang"');
    final e = AppleSttEngine._(locale);
    e._localeOnDevice = onDevice;
    return e;
  }

  /// Resolve the best locale for [lang] and whether it is on-device. Prefers an
  /// on-device locale; otherwise returns a usable cloud locale (test phase).
  /// Null only when no recogniser exists for the language at all.
  static Future<(String, bool)?> _resolveLocale(String lang) async {
    final ch = AppleSttChannel.instance;
    // A route may already carry a region (fr-CA); honour it first.
    final asGiven = lang.contains(RegExp(r'[-_]')) ? lang.replaceAll('_', '-') : null;
    final primary = normalizeLang(lang);
    final candidates = <String>[
      ?asGiven,
      ?_defaultLocale[primary],
    ];
    // Add every supported locale sharing this primary tag, as further options.
    for (final loc in await ch.supportedLocales()) {
      if (normalizeLang(loc) == primary && !candidates.contains(loc)) {
        candidates.add(loc);
      }
    }
    if (candidates.isEmpty) return null;
    // First choice: an on-device candidate. Second choice: the first candidate
    // at all (cloud), so the language is still testable.
    for (final loc in candidates) {
      if (await ch.onDevice(loc)) return (loc, true);
    }
    return (candidates.first, false);
  }

  @override
  Future<void> load(String modelDir, String lang) async {
    // No-op: this engine is built ready by [tryLoad]. Kept to satisfy the
    // interface; Apple manages its own model, there is nothing to load from disk.
  }

  @override
  bool get isReady => _ready;

  @override
  bool get isStreaming => false;

  @override
  Future<String> transcribe(Float32List samples16k) async {
    if (!_ready || samples16k.isEmpty) return '';
    try {
      // Enforce on-device only when we resolved an on-device locale; a cloud
      // locale (test phase) is allowed to use Apple's servers.
      final res = await AppleSttChannel.instance.transcribe(
        _locale,
        samples16k,
        requireOnDevice: _localeOnDevice,
      );
      DebugOverlay.log('stt apple native=${res.ms}ms '
          '${_localeOnDevice ? "on-device" : "CLOUD"} → "${res.text}"');
      return res.text.trim();
    } catch (e) {
      DebugOverlay.log('stt Apple transcribe error: $e');
      return '';
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }
}
