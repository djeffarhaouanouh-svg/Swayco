import 'package:web/web.dart' as web;

/// Web implementation: walk LiveKit's hidden audio container and apply the
/// volume to every `<audio>` element it created for remote participants.
///
/// `volume` is honoured directly by desktop browsers. On iOS Safari the
/// `HTMLMediaElement.volume` property is read-only (only the hardware
/// buttons change it), so we *also* drive `muted` — which iOS does respect
/// — to guarantee a hard 0 % cut of the original voice while the
/// translation is playing.
void applyLiveKitRemoteVolumeWeb(double volume) {
  final container = web.document.getElementById('livekit_audio_container');
  if (container == null) return;
  // Every child of LiveKit's container is an <audio> element it created.
  final audios = container.getElementsByTagName('audio');
  final muted = volume <= 0.001;
  for (var i = 0; i < audios.length; i++) {
    final el = audios.item(i);
    if (el == null) continue;
    final audio = el as web.HTMLAudioElement;
    audio.volume = volume;
    audio.muted = muted;
  }
}
