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
  /// [localTrack] is the LiveKit local audio track (type-erased as Object? to
  /// avoid importing platform-specific types in shared code). The web
  /// implementation casts it dynamically to extract the underlying
  /// MediaStreamTrack and clone it; native ignores it and records via `record`.
  ///
  /// Callbacks fire on the main isolate:
  /// - [onTranslation]`(orig, trans, lang, audioB64)` — one segment finalised +
  ///   translated; audioB64 is the pre-generated Grok mp3 (base64), may be empty.
  /// - [onPartial]`(text)` — interim transcript (live caption), best-effort.
  /// - [onError]`(code)` — a recoverable pipeline error.
  /// [captureLocalMic] true = capture MY mic (web: clone LiveKit track or
  /// getUserMedia fallback); false = capture remote participant voice.
  Future<void> start({
    required Uri wsUrl,
    Object? localTrack,
    bool captureLocalMic = true,
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
