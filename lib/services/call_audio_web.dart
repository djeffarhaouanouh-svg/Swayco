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

void markTranslationPlaying() => _markPlaying();
void markTranslationDone() => _scheduleClear();

void _markPlaying() {
  _playing = true;
  _clearTimer?.cancel();
  // Safety: clear even if 'ended' never fires.
  _clearTimer = Timer(const Duration(seconds: 8), () => _playing = false);
}

void _scheduleClear() {
  _clearTimer?.cancel();
  // Hangover so the speaker tail isn't re-captured.
  _clearTimer = Timer(const Duration(milliseconds: 500), () => _playing = false);
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
extension type _SpeechSynthesisUtterance._(JSObject _) implements JSObject {
  external set volume(num v);
  external set text(String v);
}
extension type _SpeechSynthesisObj(JSObject _) implements JSObject {
  external void speak(_SpeechSynthesisUtterance u);
}

@JS('speechSynthesis')
external JSObject get _speechSynthesisJs;

@JS('new SpeechSynthesisUtterance')
external _SpeechSynthesisUtterance _newSpeechSynthesisUtterance();

/// Call SYNCHRONOUSLY inside a user-gesture handler so iOS Safari unlocks
/// speechSynthesis for subsequent non-gesture FlutterTts.speak() calls.
void armSpeechSynthesis() {
  try {
    final utt = _newSpeechSynthesisUtterance();
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
    el.onended = ((web.Event _) => _scheduleClear()).toJS;
    _markPlaying();
    await el.play().toDart;
    return true;
  } catch (_) {
    _scheduleClear();
    return false;
  }
}
