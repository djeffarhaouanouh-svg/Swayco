/// Controls the playback volume of LiveKit's remote audio on the web.
///
/// On web, LiveKit plays every remote participant's audio through its own
/// hidden `<audio>` elements (inside `#livekit_audio_container`). Those
/// elements are unreachable by `flutter_webrtc`'s `Helper.setVolume`, which
/// on web only pokes a non-existent `volume` track-constraint — a silent
/// no-op. The web implementation here drives the DOM elements directly.
///
/// Resolves to a no-op on every non-web platform, where `Helper.setVolume`
/// already controls remote audio through the native audio session.
library;

export 'livekit_web_audio_stub.dart'
    if (dart.library.js_interop) 'livekit_web_audio_web.dart';
