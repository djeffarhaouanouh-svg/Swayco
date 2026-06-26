import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Streams the **local** microphone as PCM16 (16 kHz) to the backend Grok STT
/// WebSocket proxy and surfaces translation results.
///
/// IMPORTANT: STT runs on the LOCAL outgoing mic, never the remote track. The
/// captured audio MUST be acoustic-echo-cancelled, otherwise the mic re-captures
/// the translated voice playing out the loudspeaker and the STT transcribes it
/// as if the local user spoke it (feedback loop). On the web the browser gives
/// AEC via the `echoCancellation` constraint; native (option "b") must fork the
/// stream LiveKit already AEC-processed. See the on-disk memory "STT on local mic".
abstract class GrokMicStreamer {
  /// Open the WebSocket at [wsUrl] and start streaming mic PCM to it.
  ///
  /// [localTrack] is the LiveKit local mic track; the native implementation will
  /// fork it (already AEC'd). The web implementation captures its own AEC'd mic
  /// via `getUserMedia` and may ignore it.
  ///
  /// Callbacks fire on the main isolate:
  /// - [onTranslation]`(orig, trans, lang, audioB64)` — one segment finalised +
  ///   translated; audioB64 is the pre-generated Grok mp3 (base64), may be empty.
  /// - [onPartial]`(text)` — interim transcript (live caption), best-effort.
  /// - [onError]`(code)` — a recoverable pipeline error.
  Future<void> start({
    required Uri wsUrl,
    MediaStreamTrack? localTrack,
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  });

  Future<void> stop();

  bool get isRunning;

  /// True once the underlying socket is open and PCM is flowing.
  bool get isStreaming;
}
