import 'grok_mic_streamer_base.dart';

GrokMicStreamer createGrokMicStreamer() => _IoGrokMicStreamer();

/// Native stub. The realtime local-mic pipeline is **web-first**: native needs
/// option "b" (fork the stream LiveKit already captured + AEC-processed, via a
/// platform channel if `livekit_client` doesn't expose the local mic PCM). An
/// independent `record` stream (option "a") is a dead end on native — no AEC, so
/// it would re-transcribe the loudspeaker output into a feedback loop.
///
/// Until that lands, native keeps the existing chunk pipeline; this streamer
/// reports "unsupported" so the port can fall back / surface it in diagnostics
/// instead of pretending to run.
class _IoGrokMicStreamer implements GrokMicStreamer {
  @override
  bool get isRunning => false;

  @override
  bool get isStreaming => false;

  @override
  Future<void> start({
    required Uri wsUrl,
    dynamic localTrack,
    required void Function(String orig, String trans, String lang, String audioB64)
        onTranslation,
    void Function(String partial)? onPartial,
    void Function(String error)? onError,
  }) async {
    onError?.call('native_unsupported');
  }

  @override
  Future<void> stop() async {}
}
