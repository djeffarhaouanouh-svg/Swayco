import 'dart:async';
import 'dart:typed_data';

/// Native: no web-audio unlock needed; call_screen uses audioplayers directly.
void armCallAudio() {}
void armSpeechSynthesis() {}
void resumeSpeechSynthesisIfPaused() {}

Future<bool> playTranslatedMp3(Uint8List bytes) async => false;

// Half-duplex gate: true while a translation plays out the loudspeaker. The mic
// streamer drops audio for that window so we don't re-capture and re-translate
// our own playback (the "device answers itself" loop).
//
// 128c8e4 removed this gate on WEB only, and for a reason specific to web: that
// streamer ships mic PCM continuously, so pausing SEND chopped the audio into
// windows too short for the remote STT. The native streamer segments utterances
// locally with its own VAD, so a pause costs nothing but the echo it suppresses.
// The one thing it does cost is barge-in: you cannot interrupt a translation.
bool _playing = false;
Timer? _clearTimer;
Timer? _safetyTimer;

bool get isTranslationPlaying => _playing;

void markTranslationPlaying({int textLength = 0}) {
  _playing = true;
  _clearTimer?.cancel();
  _clearTimer = null;
  // Backstop: Kokoro's completion event can be missed (playback error, player
  // reset mid-utterance). Without this a lost markTranslationDone would wedge
  // the mic shut for the rest of the call. Sized off the text at a slow speech
  // rate, then bounded.
  _safetyTimer?.cancel();
  final ms = (1500 + textLength * 90).clamp(1500, 15000);
  _safetyTimer = Timer(Duration(milliseconds: ms), () {
    _playing = false;
    _safetyTimer = null;
  });
}

void markTranslationDone() {
  _safetyTimer?.cancel();
  _safetyTimer = null;
  _clearTimer?.cancel();
  // Short hangover so the speaker tail and the AEC's own delay line settle
  // before the mic is trusted again.
  _clearTimer = Timer(const Duration(milliseconds: 300), () {
    _playing = false;
    _clearTimer = null;
  });
}

/// True while the user has muted their mic. The native mic streamers read this
/// and drop the audio, so muting stops the *translation* too — not just the
/// LiveKit voice track. Module-level, so it survives a translation re-attach;
/// call_screen resets it to false on connect.
bool _sendMuted = false;
bool get isSendMuted => _sendMuted;
void setSendMuted(bool v) => _sendMuted = v;

void registerCaptureContext(dynamic ctx) {}
