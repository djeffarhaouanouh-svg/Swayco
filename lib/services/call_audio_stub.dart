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
  // Backstop: the local TTS completion event can be missed (playback error, player
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

/// Notified on every *change* of [isSendMuted].
///
/// Reading the flag per audio buffer is enough to DROP the audio, but not to
/// release the microphone: the mute is a one-off event and the capture callback
/// only fires while a capture is open. The native STT streamer subscribes here
/// so it can close its `record` capture outright — see the listener in
/// `sway_local_mic_streamer_io.dart`. Without it a muted call still holds a
/// SECOND capture open on a mic LiveKit is already using.
final List<void Function(bool muted)> _sendMutedListeners = [];

void addSendMutedListener(void Function(bool muted) listener) =>
    _sendMutedListeners.add(listener);

void removeSendMutedListener(void Function(bool muted) listener) =>
    _sendMutedListeners.remove(listener);

void setSendMuted(bool v) {
  if (v == _sendMuted) return;
  _sendMuted = v;
  // Copy first: a listener is free to unsubscribe itself from inside the call.
  for (final listener in List.of(_sendMutedListeners)) {
    try {
      listener(v);
    } catch (_) {
      // A broken listener must never take the mute itself down with it.
    }
  }
}

void registerCaptureContext(dynamic ctx) {}
