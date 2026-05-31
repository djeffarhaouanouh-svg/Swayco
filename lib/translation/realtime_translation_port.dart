import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

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
/// Next steps (server-side recommended):
/// - Create ephemeral OpenAI Realtime sessions in `backend` (never ship API keys in Flutter).
/// - Stream microphone audio to your bridge; receive translated audio or text.
/// - Optionally mix translated audio or publish via a second LiveKit track / data channel.
abstract class RealtimeTranslationPort {
  Future<void> attachToRoom(
    Room room, {
    required TranslationRoute route,
  });

  Future<void> detach();

  /// When non-null, widgets can wrap [buildTranslationAudioOverlay] in a
  /// [ListenableBuilder] so hidden WebRTC playback rebuilds.
  Listenable? get translationListenable => null;

  /// e.g. tiny [RTCVideoView] for translated remote audio (OpenAI path).
  Widget? buildTranslationAudioOverlay() => null;

  /// Shown in-call for immediate feedback (progress, chips).
  TranslationFeedbackPhase get translationFeedbackPhase => TranslationFeedbackPhase.hidden;

  /// LiveKit active speaker list includes a remote participant (for a subtle pulse).
  bool get translationRemoteVoiceHot => false;

  /// True while the translated audio is actually playing back. Lets the
  /// call screen duck the original remote audio for the exact window the
  /// translation can be heard.
  bool get translationSpeaking => false;

  /// Set the playback volume of the translated audio in [0, 1]. No-op when
  /// the implementation has no translated audio stream of its own.
  Future<void> setTranslatedAudioVolume(double volume) async {}
}

/// Default: no processing; keeps call path simple until you add an adapter.
class NoOpRealtimeTranslation implements RealtimeTranslationPort {
  const NoOpRealtimeTranslation();
  @override
  Future<void> attachToRoom(
    Room room, {
    required TranslationRoute route,
  }) async {}

  @override
  Future<void> detach() async {}

  @override
  Listenable? get translationListenable => null;

  @override
  Widget? buildTranslationAudioOverlay() => null;

  @override
  TranslationFeedbackPhase get translationFeedbackPhase => TranslationFeedbackPhase.hidden;

  @override
  bool get translationRemoteVoiceHot => false;

  @override
  bool get translationSpeaking => false;

  @override
  Future<void> setTranslatedAudioVolume(double volume) async {}
}
