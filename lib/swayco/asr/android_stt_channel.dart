import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// One transcription result from Android's native recogniser.
class AndroidSttResult {
  const AndroidSttResult(this.text, this.ms, this.onDevice);
  final String text;

  /// Native recognition time, milliseconds.
  final int ms;

  /// Whether the recognition actually ran on-device (vs Google's cloud).
  final bool onDevice;
}

/// Thin Dart wrapper over the native `SwayAndroidStt` method channel (Android).
///
/// The Android twin of `AppleSttChannel`. The channel is only registered on
/// Android (see `MainActivity`), so every method first checks the platform and
/// returns a safe default elsewhere — the engine that uses it is already gated
/// to Android, this is just belt-and-braces.
class AndroidSttChannel {
  AndroidSttChannel._();
  static final AndroidSttChannel instance = AndroidSttChannel._();

  static const MethodChannel _channel = MethodChannel('swayco/android_stt');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Whether this device can run the on-device recogniser at all: API >= 33 and
  /// `SpeechRecognizer.isOnDeviceRecognitionAvailable`. False → the caller falls
  /// back to the bundled Whisper.
  Future<bool> capable() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('capable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The on-device languages currently INSTALLED (BCP-47), read from
  /// `checkRecognitionSupport().installedOnDeviceLanguages`. Empty when none are
  /// installed (e.g. an emulator, or a phone that has not downloaded any voice
  /// model) or on failure. This is the privacy-critical list: only a language in
  /// it can be recognised without sending audio to Google's servers.
  Future<List<String>> onDeviceLanguages() async {
    if (!_isAndroid) return const [];
    try {
      final ids =
          await _channel.invokeMethod<List<Object?>>('onDeviceLanguages');
      return ids?.whereType<String>().toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Load the on-device model ahead of the first phrase by running a throwaway
  /// silent recognition — kills the ~1.4 s cold-start so the first real phrase is
  /// already warm (~440 ms). Best-effort; returns whether the recogniser is up.
  Future<bool> warmup(String locale, {bool requireOnDevice = true}) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('warmup', {
            'locale': locale,
            'requireOnDevice': requireOnDevice,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Destroy the persistent recogniser at end of call.
  Future<void> release() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }

  /// Transcribe one clip. [samples] are 16 kHz mono Float32 in [-1, 1] — exactly
  /// what the VAD hands the engine. When [requireOnDevice] the native side uses
  /// the on-device recogniser and sets `EXTRA_PREFER_OFFLINE`; otherwise it may
  /// use Google's cloud (test phase). Returns the recognised text, the native
  /// timing, and whether the run was on-device.
  Future<AndroidSttResult> transcribe(
    String locale,
    Float32List samples, {
    int sampleRate = 16000,
    bool requireOnDevice = true,
  }) async {
    if (!_isAndroid) return const AndroidSttResult('', 0, false);
    final bytes = samples.buffer.asUint8List(
      samples.offsetInBytes,
      samples.length * 4,
    );
    final res =
        await _channel.invokeMethod<Map<Object?, Object?>>('transcribe', {
      'locale': locale,
      'samples': bytes,
      'sampleRate': sampleRate,
      'requireOnDevice': requireOnDevice,
    });
    final text = (res?['text'] as String?) ?? '';
    final ms = (res?['ms'] as int?) ?? 0;
    final onDevice = (res?['onDevice'] as bool?) ?? false;
    return AndroidSttResult(text, ms, onDevice);
  }
}
