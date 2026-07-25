import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Speech-recognition authorization state, mirroring `SFSpeechRecognizerAuthorizationStatus`.
enum AppleSttAuth { notDetermined, denied, restricted, authorized, unknown }

AppleSttAuth _authFrom(int? raw) {
  switch (raw) {
    case 0:
      return AppleSttAuth.notDetermined;
    case 1:
      return AppleSttAuth.restricted; // blocked by policy/MDM — no prompt possible
    case 2:
      return AppleSttAuth.denied;
    case 3:
      return AppleSttAuth.authorized;
    default:
      return AppleSttAuth.unknown;
  }
}

/// One transcription result from Apple's on-device recogniser.
class AppleSttResult {
  const AppleSttResult(this.text, this.ms);
  final String text;

  /// Native decode time, milliseconds.
  final int ms;
}

/// Thin Dart wrapper over the native `SwayAppleStt` method channel (iOS).
///
/// The channel is only registered on iOS (see `SceneDelegate`), so every method
/// here first checks the platform and returns a safe default elsewhere — the
/// engine that uses it is already gated to iOS, this is just belt-and-braces.
class AppleSttChannel {
  AppleSttChannel._();
  static final AppleSttChannel instance = AppleSttChannel._();

  static const MethodChannel _channel = MethodChannel('swayco/apple_stt');

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Current authorization status, without prompting.
  Future<AppleSttAuth> authStatus() async {
    if (!_isIOS) return AppleSttAuth.unknown;
    try {
      return _authFrom(await _channel.invokeMethod<int>('authStatus'));
    } catch (_) {
      return AppleSttAuth.unknown;
    }
  }

  /// Request authorization, prompting the user the first time. On a device where
  /// speech is blocked by policy (MDM/Screen Time) this returns [restricted]
  /// with no prompt shown.
  Future<AppleSttAuth> requestAuth() async {
    if (!_isIOS) return AppleSttAuth.unknown;
    try {
      return _authFrom(await _channel.invokeMethod<int>('requestAuth'));
    } catch (_) {
      return AppleSttAuth.unknown;
    }
  }

  /// Every locale the OS can create a recogniser for (cloud OR on-device).
  Future<List<String>> supportedLocales() async {
    if (!_isIOS) return const [];
    try {
      final ids = await _channel.invokeMethod<List<Object?>>('supportedLocales');
      return ids?.whereType<String>().toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [locale] has its dictation asset installed so recognition runs
  /// entirely on-device. This is the privacy-critical check: if false, using
  /// Apple STT would either fail (`requiresOnDeviceRecognition`) or send audio
  /// to Apple's servers. It is per-device, per-language, and can flip to true
  /// after the OS downloads the asset.
  Future<bool> onDevice(String locale) async {
    if (!_isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('onDevice', {'locale': locale}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the recogniser for [locale] is currently available at all.
  Future<bool> available(String locale) async {
    if (!_isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('available', {'locale': locale}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Transcribe one clip, ON-DEVICE ONLY. [samples] are 16 kHz mono Float32 in
  /// [-1, 1] — exactly what the VAD hands the engine. Throws if the locale has
  /// no on-device asset (the native side refuses to leave the device).
  Future<AppleSttResult> transcribe(
    String locale,
    Float32List samples, {
    int sampleRate = 16000,
    bool requireOnDevice = true,
  }) async {
    if (!_isIOS) return const AppleSttResult('', 0);
    final bytes = samples.buffer.asUint8List(
      samples.offsetInBytes,
      samples.length * 4,
    );
    final res = await _channel.invokeMethod<Map<Object?, Object?>>('transcribe', {
      'locale': locale,
      'samples': bytes,
      'sampleRate': sampleRate,
      'requireOnDevice': requireOnDevice,
    });
    final text = (res?['text'] as String?) ?? '';
    final ms = (res?['ms'] as int?) ?? 0;
    return AppleSttResult(text, ms);
  }
}
