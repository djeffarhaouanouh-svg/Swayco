import 'package:flutter/widgets.dart';

import 'translation_route.dart';

/// UX phases for translation (perceived responsiveness, not lip-sync).
enum TranslationFeedbackPhase {
  hidden,
  /// Room ready, waiting for remote / pipeline idle.
  standby,
  /// Fetching token, SDP, or WebRTC connecting.
  working,
  /// OpenAI path connected and receiving media.
  live,
}

/// Abstraction for bidirectional realtime speech translation.
///
/// DIAGNOSTIC BUILD 6.1.2+8: the `attachToRoom` parameter type was
/// `livekit_client.Room` — that's the only place the LiveKit Dart
/// package types leaked into the interface. Switched to `Object?` so
/// the file no longer imports `package:livekit_client/...`, which keeps
/// the whole call-path module chain free of LiveKit at boot.
abstract class RealtimeTranslationPort {
  Future<void> attachToRoom(
    Object? room, {
    required TranslationRoute route,
  });

  Future<void> detach();

  /// When non-null, widgets can wrap [buildTranslationAudioOverlay] in a
  /// [ListenableBuilder] so hidden WebRTC playback rebuilds.
  Listenable? get translationListenable => null;

  /// e.g. tiny [RTCVideoView] for translated remote audio (OpenAI path).
  Widget? buildTranslationAudioOverlay() => null;

  /// Shown in-call for immediate feedback (progress, chips).
  TranslationFeedbackPhase get translationFeedbackPhase =>
      TranslationFeedbackPhase.hidden;

  /// LiveKit active speaker list includes a remote participant (for a subtle pulse).
  bool get translationRemoteVoiceHot => false;

  /// True while the translated audio is actually playing back.
  bool get translationSpeaking => false;

  /// Set the playback volume of the translated audio in [0, 1].
  Future<void> setTranslatedAudioVolume(double volume) async {}
}

/// Default: no processing. The diagnostic build wires this up everywhere
/// the previous `OpenAiRealtimeTranslation` used to be wired.
class NoOpRealtimeTranslation implements RealtimeTranslationPort {
  const NoOpRealtimeTranslation();
  @override
  Future<void> attachToRoom(
    Object? room, {
    required TranslationRoute route,
  }) async {}

  @override
  Future<void> detach() async {}

  @override
  Listenable? get translationListenable => null;

  @override
  Widget? buildTranslationAudioOverlay() => null;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase =>
      TranslationFeedbackPhase.hidden;

  @override
  bool get translationRemoteVoiceHot => false;

  @override
  bool get translationSpeaking => false;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {}
}
