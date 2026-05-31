import 'package:flutter/widgets.dart';

import '../services/diag.dart';
import 'realtime_translation_port.dart';
import 'translation_route.dart';

/// DIAGNOSTIC BUILD 6.1.2+8 — this file was originally ~600 lines of
/// LiveKit + WebRTC + OpenAI Realtime wiring. It's been replaced with a
/// no-op stub so the boot path stops loading `package:livekit_client`
/// and `package:flutter_webrtc` Dart-side. Combined with the same two
/// packages being commented out of pubspec.yaml, that takes their
/// native plugin registrations out of the engine's startup sequence on
/// iOS / Android too — the only configuration that lets us prove (or
/// rule out) those plugins as the cause of the post-splash black screen
/// on Release builds on real devices.
///
/// Restoring the real implementation is one `git revert` once the
/// diagnostic build's behavior on TestFlight / Play Store is known.
class OpenAiRealtimeTranslation extends ChangeNotifier
    implements RealtimeTranslationPort {
  OpenAiRealtimeTranslation() {
    Diag.ping('openai-translation-stub-constructed');
  }

  @override
  Future<void> attachToRoom(
    Object? room, {
    required TranslationRoute route,
  }) async {
    Diag.ping('openai-translation-stub-attach');
  }

  @override
  Future<void> detach() async {
    Diag.ping('openai-translation-stub-detach');
  }

  @override
  Listenable? get translationListenable => this;

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
