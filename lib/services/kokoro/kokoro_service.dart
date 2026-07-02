import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_downloader.dart';
import 'tts_player.dart';
import 'voice_downloader.dart';

/// Kokoro TTS — 100 % local inference via ONNX Runtime.
///
/// Usage:
/// ```dart
/// await KokoroService.instance.init();
/// await KokoroService.instance.ensureLanguageInstalled('fr');
/// await KokoroService.instance.speak(
///   text: translatedText,
///   languageCode: 'fr',
///   voice: 'ff_siwis',
/// );
/// ```
class KokoroService {
  KokoroService._();
  static final instance = KokoroService._();

  final _modelDl = ModelDownloader();
  final _voiceDl = VoiceDownloader();
  final _player = TtsPlayer();

  bool _modelReady = false;
  bool _initializing = false;

  static const _prefKeyDownloadedVoices = 'kokoro_downloaded_voices';
  static const _prefKeySelectedVoice = 'kokoro_selected_voice';
  static const _prefKeySelectedLang = 'kokoro_selected_lang';

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Call once at app start (e.g. in main() after runApp).
  /// Downloads the model if absent, then loads the ONNX session.
  /// Safe to call multiple times — idempotent.
  Future<void> init({void Function(double)? onProgress}) async {
    if (kIsWeb) return; // Kokoro runs on native only
    if (_modelReady || _initializing) return;
    _initializing = true;
    try {
      final file = await _modelDl.ensureModel(onProgress: onProgress);
      await _player.loadModel(file.path);
      _modelReady = true;

      // Restore previously installed voices
      final prefs = await SharedPreferences.getInstance();
      final downloaded =
          prefs.getStringList(_prefKeyDownloadedVoices) ?? [];
      for (final voice in downloaded) {
        await _ensureVoiceFile(voice);
      }
    } catch (e) {
      debugPrint('[kokoro] init error: $e');
    } finally {
      _initializing = false;
    }
  }

  bool get isReady => _modelReady && _player.isReady;

  // ── Language / voice management ────────────────────────────────────────────

  /// Returns the default Kokoro voice name for [langCode].
  static String defaultVoiceFor(String langCode) =>
      VoiceDownloader.defaultVoiceFor(langCode);

  /// Ensures the voice file for [langCode] is present on disk.
  /// Shows download progress via [onProgress] (0.0 → 1.0).
  Future<void> ensureLanguageInstalled(
    String langCode, {
    void Function(double)? onProgress,
  }) async {
    if (kIsWeb) return;
    final voice = defaultVoiceFor(langCode);
    await _ensureVoiceFile(voice, onProgress: onProgress);

    // Persist installed voices list
    final prefs = await SharedPreferences.getInstance();
    final downloaded =
        prefs.getStringList(_prefKeyDownloadedVoices)?.toSet() ?? {};
    downloaded.add(voice);
    await prefs.setStringList(
        _prefKeyDownloadedVoices, downloaded.toList());
    await prefs.setString(_prefKeySelectedLang, langCode);
    await prefs.setString(_prefKeySelectedVoice, voice);
  }

  /// Whether [langCode]'s voice file is already on disk.
  Future<bool> isLanguageInstalled(String langCode) async {
    if (kIsWeb) return false;
    final voice = defaultVoiceFor(langCode);
    final dir = await VoiceDownloader.voicesDir();
    return File('${dir.path}/$voice.bin').exists();
  }

  // ── Synthesis ──────────────────────────────────────────────────────────────

  /// Synthesise [text] and play it locally.
  /// Falls back silently if the model or voice is not ready.
  Future<void> speak({
    required String text,
    required String languageCode,
    required String voice,
  }) async {
    if (kIsWeb || !isReady) return;
    if (text.trim().isEmpty) return;
    try {
      final voicePath = await _voiceFilePath(voice);
      if (voicePath == null) {
        // Voice not yet downloaded — try to grab it now
        await _ensureVoiceFile(voice);
        final path = await _voiceFilePath(voice);
        if (path == null) return;
        await _player.speak(text, languageCode, path);
      } else {
        await _player.speak(text, languageCode, voicePath);
      }
    } catch (e) {
      debugPrint('[kokoro] speak error: $e');
    }
  }

  Future<void> stop() async {
    if (kIsWeb) return;
    await _player.stop();
  }

  Future<void> dispose() async {
    await _player.dispose();
    _modelReady = false;
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

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _ensureVoiceFile(
    String voiceName, {
    void Function(double)? onProgress,
  }) async {
    try {
      await _voiceDl.ensureVoice(voiceName, onProgress: onProgress);
    } catch (e) {
      debugPrint('[kokoro] voice download error ($voiceName): $e');
    }
  }

  Future<String?> _voiceFilePath(String voiceName) async {
    final dir = await VoiceDownloader.voicesDir();
    final file = File('${dir.path}/$voiceName.bin');
    if (await file.exists()) return file.path;
    return null;
  }
}
