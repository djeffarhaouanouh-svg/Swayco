/// Streams the **local** microphone as PCM16 (16 kHz) to the backend cloud STT
/// WebSocket proxy and surfaces translation results.
///
/// IMPORTANT: STT runs on the LOCAL outgoing mic, never the remote track. The
/// captured audio MUST be acoustic-echo-cancelled, otherwise the mic re-captures
/// the translated voice playing out the loudspeaker and the STT transcribes it
/// as if the local user spoke it (feedback loop). On the web the browser gives
/// AEC via the `echoCancellation` constraint; native (option "b") must fork the
/// stream LiveKit already AEC-processed. See the on-disk memory "STT on local mic".
abstract class SwayMicStreamer {
  /// Open the WebSocket at [wsUrl] and start streaming mic PCM to it.
  ///
  /// [localTrack] is the LiveKit local audio track (type-erased as Object? to
  /// avoid importing platform-specific types in shared code). The web
  /// implementation casts it dynamically to extract the underlying
  /// MediaStreamTrack and clone it; native ignores it and records via `record`.
  ///
  /// Callbacks fire on the main isolate:
  /// - [onTranslation]`(orig, trans, lang, audioB64)` — one segment finalised +
  ///   translated; audioB64 is the pre-generated cloud mp3 (base64), may be empty.
  /// - [onPartial]`(text)` — interim transcript (live caption), best-effort.
  /// - [onError]`(code)` — a recoverable pipeline error.
  /// [captureLocalMic] true = capture MY mic (web: clone LiveKit track or
  /// getUserMedia fallback); false = capture remote participant voice.
  ///
  /// [sourceLang] / [targetLang] are the route's BCP-47 tags. The the cloud engine path
  /// encodes them in [wsUrl] and ignores them; the on-device native path needs
  /// them directly, to pick which STT model to load and which language to
  /// translate into.
  Future<void> start({
    required Uri wsUrl,
    Object? localTrack,
    bool captureLocalMic = true,
    String sourceLang = '',
    String targetLang = '',
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  });

  Future<void> stop();

  /// True while the mic has been released after a stretch of silence, to save
  /// battery. Only the on-device native path dozes; the cloud engine paths hold their
  /// socket open for the whole call.
  bool get isDozing => false;

  /// Re-open the mic after [isDozing]. The caller drives this from LiveKit's
  /// own speaking detection — WebRTC computes it for the call regardless, so
  /// it costs nothing, and it is the only signal still available once our own
  /// capture is closed.
  Future<void> wake() async {}

  bool get isRunning;

  /// True once the underlying socket is open and PCM is flowing.
  bool get isStreaming;

  /// True when `onTranslation` reports the whole session transcript so far,
  /// growing with each callback (the cloud engine keeps session context and re-sends it).
  /// The caller must then publish only the delta, and dedup repeats.
  ///
  /// False when each callback is one independent, VAD-clipped utterance — the
  /// on-device path. Applying delta/dedup there would truncate a sentence that
  /// happens to extend the previous one, and swallow a repeated short word.
  bool get accumulatesTranscript;

}
