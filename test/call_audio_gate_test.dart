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

  // Reading the flag per buffer silences the stream but keeps the microphone
  // open — and a second capture held on a mic LiveKit also holds is what drove
  // the signal into clipping. The native streamer releases it on this signal.
  group('sendMuted listeners', () {
    test('fire on each transition, with the new value', () {
      final seen = <bool>[];
      void listener(bool muted) => seen.add(muted);
      addSendMutedListener(listener);
      addTearDown(() => removeSendMutedListener(listener));

      setSendMuted(true);
      setSendMuted(false);
      expect(seen, [true, false]);
    });

    test('do not fire when the value is unchanged', () {
      final seen = <bool>[];
      void listener(bool muted) => seen.add(muted);
      addSendMutedListener(listener);
      addTearDown(() => removeSendMutedListener(listener));

      setSendMuted(true);
      setSendMuted(true);
      // A repeated mute must not restart the capture it just released.
      expect(seen, [true]);
    });

    test('a removed listener stops being called', () {
      final seen = <bool>[];
      void listener(bool muted) => seen.add(muted);
      addSendMutedListener(listener);
      setSendMuted(true);
      removeSendMutedListener(listener);
      setSendMuted(false);
      // A streamer that has stopped must never drive its dead recorder again.
      expect(seen, [true]);
    });

    test('a throwing listener cannot break the mute itself', () {
      void bad(bool muted) => throw StateError('recorder is gone');
      addSendMutedListener(bad);
      addTearDown(() => removeSendMutedListener(bad));

      expect(() => setSendMuted(true), returnsNormally);
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
