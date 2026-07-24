import 'package:audioplayers/audioplayers.dart';

/// The audio-session context that makes on-device (Piper / ja) TTS playback
/// behave like `flutter_tts` during a call.
///
/// A bare `AudioPlayer()` plays on the **media** route: during a call that comes
/// out the wrong output (loud-speaker instead of the ear/route the call is on)
/// and fights the live WebRTC session. `flutter_tts` never has this problem —
/// the OS speech engine plays straight into the call's already-active session.
///
/// This context gives audioplayers the same shape: it rides the
/// **voice-communication** route (earpiece / speaker / Bluetooth, whatever the
/// call is using) and **mixes with** the WebRTC audio instead of seizing it.
/// The far voice is ducked by the app itself (the `ttsSpeaking` gate), so we do
/// NOT ask the OS to duck as well — that would duck twice.
final AudioContext kCallTtsAudioContext = AudioContext(
  iOS: AudioContextIOS(
    category: AVAudioSessionCategory.playAndRecord,
    options: const {
      // Mix, don't take over — LiveKit owns the call session.
      AVAudioSessionOptions.mixWithOthers,
      // NO defaultToSpeaker. It forced the translated voice out the
      // loudspeaker while the call itself now runs on the earpiece, so the peer
      // heard the translation and NOT the real voice — the two ended up on
      // different routes. Without it this player rides whatever route the call
      // is on, which is what the doc above always claimed it did.
      AVAudioSessionOptions.allowBluetooth,
      AVAudioSessionOptions.allowBluetoothA2DP,
    },
  ),
  android: const AudioContextAndroid(
    isSpeakerphoneOn: false,
    stayAwake: false,
    // speech over the call route, and don't grab audio focus (the app ducks the
    // far voice itself — grabbing focus here would duck the call a second time).
    contentType: AndroidContentType.speech,
    usageType: AndroidUsageType.voiceCommunication,
    audioFocus: AndroidAudioFocus.none,
  ),
);

/// Apply [kCallTtsAudioContext] to [player] once. Swallows failures — a player
/// that could not take the context still plays (on the media route), which is
/// exactly today's behaviour, so this can only improve routing, never break it.
Future<void> applyCallTtsAudioContext(AudioPlayer player) async {
  try {
    await player.setAudioContext(kCallTtsAudioContext);
  } catch (_) {
    // Older platform, unsupported option set — fall back to the default route.
  }
}
