import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// A single, reusable <audio> element + AudioContext. WebKit (Safari / Chrome on
// iOS) only allows audio playback once it has been started inside a real user
// gesture. We arm this element in the "Accept call" onTap (a valid gesture);
// after that, programmatic playback of incoming translations works.

web.AudioContext? _ctx;
web.HTMLAudioElement? _el;

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
    await el.play().toDart;
    return true;
  } catch (_) {
    return false;
  }
}
