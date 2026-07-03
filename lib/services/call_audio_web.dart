import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// A single, reusable <audio> element + AudioContext. WebKit (Safari / Chrome on
// iOS) only allows audio playback once it has been started inside a real user
// gesture. We arm this element in the "Accept call" onTap (a valid gesture);
// after that, programmatic playback of incoming translations works.

web.AudioContext? _ctx;
web.HTMLAudioElement? _el;

// True while a translation is playing out the speaker. The mic streamer reads
// this to PAUSE sending (half-duplex) so we don't re-capture & re-translate our
// own playback (the "device answers itself" feedback loop).
bool _playing = false;
Timer? _clearTimer;
int _playingSinceMs = 0;
bool get isTranslationPlaying => _playing;

// True when the user has muted their mic — SEND should not stream audio.
bool _sendMuted = false;
bool get isSendMuted => _sendMuted;
void setSendMuted(bool v) => _sendMuted = v;

// No-op — AudioContext.suspend/resume is unreliable on Safari (resume()
// returns a JSPromise that never resolves, leaving capture dead). Half-duplex
// is handled by the isTranslationPlaying flag in grok_mic_streamer_web.
void registerCaptureContext(dynamic ctx) {}

void markTranslationPlaying({int textLength = 0}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!_playing) _playingSinceMs = now;
  // HARD CEILING: never keep the mic gated more than 5s in a row, no matter how
  // many TTS calls stream in. This is the safety net for when the Web Speech
  // completion event stops firing after prolonged use (it becomes unreliable —
  // the "stuck after 2 min, dead even after re-dialling" bug). Without it the
  // gate sticks true and SEND is blocked forever. Once tripped, the next call
  // starts a fresh 5s window.
  if (now - _playingSinceMs > 5000) {
    _clearTimer?.cancel();
    _clearTimer = null;
    _playing = false;
    return;
  }
  _playing = true;
  // The TTS completion event (→ markTranslationDone) normally clears this the
  // instant playback ends (precise half-duplex). This timer is the fallback for
  // when that event doesn't fire: estimate the utterance from its length
  // (~90 ms/char), capped at the 5s ceiling.
  _clearTimer?.cancel();
  final estMs = (textLength * 90).clamp(1200, 5000);
  _clearTimer = Timer(Duration(milliseconds: estMs), () {
    _playing = false;
    _clearTimer = null;
  });
}

void markTranslationDone() {
  // Immediate: the mic reopens the instant the TTS finishes so the listening
  // side can reply straight away — no residual block (that lag is what made the
  // Android side go mute while the caller was still talking).
  _clearTimer?.cancel();
  _clearTimer = null;
  _playing = false;
}

// 44-byte silent WAV — enough to "start" playback inside the gesture.
const String _silentWav =
    'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=';

web.HTMLAudioElement _element() {
  final el = _el ??=
      (web.document.createElement('audio') as web.HTMLAudioElement)
        ..setAttribute('playsinline', 'true')
        ..setAttribute('autoplay', 'false');
  return el;
}

// Minimal JS-interop bindings for Web Speech API (speechSynthesis).
@JS('SpeechSynthesisUtterance')
extension type _SpeechSynthesisUtterance._(JSObject _) implements JSObject {
  external factory _SpeechSynthesisUtterance();
  external set volume(num v);
  external set text(String v);
}
extension type _SpeechSynthesisObj(JSObject _) implements JSObject {
  external void speak(_SpeechSynthesisUtterance u);
}

@JS('speechSynthesis')
external JSObject get _speechSynthesisJs;

/// Call SYNCHRONOUSLY inside a user-gesture handler so iOS Safari unlocks
/// speechSynthesis for subsequent non-gesture FlutterTts.speak() calls.
void armSpeechSynthesis() {
  try {
    final utt = _SpeechSynthesisUtterance();
    utt.volume = 0;
    utt.text = '';
    _SpeechSynthesisObj(_speechSynthesisJs).speak(utt);
  } catch (_) {}
}

/// Call this SYNCHRONOUSLY inside a user-gesture handler (Accept button).
void armCallAudio() {
  try {
    _ctx ??= web.AudioContext();
    _ctx?.resume();
    final el = _element();
    el.muted = true;
    el.src = _silentWav;
    el.play(); // fire-and-forget inside the gesture — this unlocks the element
  } catch (_) {}
}

/// Play an mp3 (Grok TTS) through the unlocked element. Returns false on failure
/// so the caller can fall back.
Future<bool> playTranslatedMp3(Uint8List bytes) async {
  try {
    final el = _element();
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'audio/mpeg'),
    );
    final url = web.URL.createObjectURL(blob);
    el.muted = false;
    el.src = url;
    el.onended = ((web.Event _) => markTranslationDone()).toJS;
    markTranslationPlaying();
    await el.play().toDart;
    return true;
  } catch (_) {
    markTranslationDone();
    return false;
  }
}
