import 'dart:typed_data';

/// Native: no web-audio unlock needed; call_screen uses audioplayers directly.
void armCallAudio() {}
void armSpeechSynthesis() {}
void resumeSpeechSynthesisIfPaused() {}

Future<bool> playTranslatedMp3(Uint8List bytes) async => false;

bool get isTranslationPlaying => false;
void markTranslationPlaying({int textLength = 0}) {}
void markTranslationDone() {}

// Unlike the rest of this stub, mute state is real (not a no-op): the
// native Grok mic streamer (grok_mic_streamer_io.dart) reads isSendMuted
// to decide whether to stream PCM to the STT backend. Before this, muting
// the call on iOS/Android only stopped the real LiveKit voice track — the
// separate translation-mic capture kept running, so muted ambient noise
// still got transcribed/translated and spoken to the peer ("the app talks
// by itself" even with both mics closed).
bool _sendMuted = false;
bool get isSendMuted => _sendMuted;
void setSendMuted(bool v) => _sendMuted = v;
void registerCaptureContext(dynamic ctx) {}
