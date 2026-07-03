import 'package:web/web.dart' as web;

/// Android/iOS Chrome: after a few utterances or a tab background, the browser
/// silently moves speechSynthesis into "paused" state. speak() returns success
/// but produces no audio. resume() wakes it up before we enqueue the next one.
void resumeSpeechSynthesisIfPaused() {
  try {
    final ss = web.window.speechSynthesis;
    if (ss.paused) ss.resume();
  } catch (_) {}
}
