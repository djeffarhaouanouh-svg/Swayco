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
  _playing = true;
  // Don't reset an already-running timer: rapid successive TTS calls would
  // push the gate back indefinitely, blocking the user's mic for too long.
  // 800 ms covers the echo-onset window; AEC + AGC-off handle the rest.
  if (_clearTimer != null) return;
  _clearTimer = Timer(const Duration(milliseconds: 800), () {
    _playing = false;
    _clearTimer = null;
  });
}

void markTranslationDone() {
  _clearTimer?.cancel();
  _clearTimer = Timer(const Duration(milliseconds: 400), () {
    _playing = false;
    _clearTimer = null;
  });
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
