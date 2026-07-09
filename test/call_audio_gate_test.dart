// The native mic gate is pure timer logic guarding two things that are painful
// to debug on a device: a "muted" user whose translation still reaches the peer,
// and a mic wedged shut for the rest of a call by a lost markTranslationDone.
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/call_audio_stub.dart';

void main() {
  setUp(() {
    setSendMuted(false);
    markTranslationDone();
  });

  group('isSendMuted', () {
    test('mute is observable by the mic streamers', () {
      expect(isSendMuted, isFalse);
      setSendMuted(true);
      expect(isSendMuted, isTrue);
      setSendMuted(false);
      expect(isSendMuted, isFalse);
    });

    test('persists across a translation re-attach (call_screen resets it)', () {
      setSendMuted(true);
      // Nothing here re-initialises the module; a re-attach would see it stale.
      expect(isSendMuted, isTrue);
    });
  });

  group('half-duplex gate', () {
    test('opens on playing, closes after done + hangover', () async {
      expect(isTranslationPlaying, isFalse);

      markTranslationPlaying(textLength: 10);
      expect(isTranslationPlaying, isTrue,
          reason: 'mic must be shut while TTS plays');

      markTranslationDone();
      expect(isTranslationPlaying, isTrue,
          reason: 'hangover keeps it shut while the speaker tail decays');

      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(isTranslationPlaying, isFalse);
    });

    test('a lost markTranslationDone cannot wedge the mic shut', () async {
      // Shortest possible safety window: 1500 ms floor for empty text.
      markTranslationPlaying(textLength: 0);
      expect(isTranslationPlaying, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(isTranslationPlaying, isTrue, reason: 'still within the backstop');

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(isTranslationPlaying, isFalse,
          reason: 'backstop must reopen the mic even with no done()');
    });

    test('safety window scales with text but stays bounded', () async {
      markTranslationPlaying(textLength: 100000);
      expect(isTranslationPlaying, isTrue);
      markTranslationDone(); // do not actually wait 15 s
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(isTranslationPlaying, isFalse);
    });

    test('done() then a new playing() re-arms the gate', () async {
      markTranslationPlaying(textLength: 5);
      markTranslationDone();
      markTranslationPlaying(textLength: 5);
      // The pending 300 ms clear from done() must not reopen the mic underneath
      // the utterance that just started.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(isTranslationPlaying, isTrue);
    });
  });
}
