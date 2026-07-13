import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/swayco/asr/transcript_guard.dart';

void main() {
  group('drops what the recogniser invented', () {
    test('the decoder stuck in a loop', () {
      expect(looksHallucinated('oui, oui, oui, oui, oui, oui, oui, oui',
          durationMs: 3000), isTrue);
      expect(looksHallucinated('Yeah. Yeah. Yeah. Yeah. Yeah.',
          durationMs: 2500), isTrue);
    });

    test('subtitle boilerplate, accents or not', () {
      expect(looksHallucinated('Sous-titrage Société Radio-Canada',
          durationMs: 1200), isTrue);
      expect(looksHallucinated('Sous-titres realises par la communaute d\'Amara.org',
          durationMs: 1500), isTrue);
      expect(looksHallucinated('Thanks for watching!', durationMs: 900), isTrue);
      expect(looksHallucinated('ご視聴ありがとうございました', durationMs: 800), isTrue);
    });

    test('no letters, or faster than a mouth can move', () {
      expect(looksHallucinated('...', durationMs: 500), isTrue);
      expect(looksHallucinated('♪♪♪', durationMs: 500), isTrue);
      expect(looksHallucinated('', durationMs: 500), isTrue);
      expect(
          looksHallucinated(
              'a' * 100, durationMs: 1000),
          isTrue);
    });

    test('stray letters instead of a phrase', () {
      // Seen in a real call: a noise the decoder could not place came out as
      // "L - L", and the peer's phone read it aloud. It carries letters, it is
      // not boilerplate, its character rate is plausible, and the loop guard
      // wants four words before it speaks up — so every other rule waved it
      // through.
      expect(looksHallucinated('L - L', durationMs: 900), isTrue);
      expect(looksHallucinated('A. A', durationMs: 700), isTrue);
      expect(looksHallucinated('T', durationMs: 400), isTrue);
      expect(looksHallucinated('m m m', durationMs: 1100), isTrue);
    });
  });

  group('keeps what a person actually said', () {
    test('ordinary sentences', () {
      expect(looksHallucinated('Bonjour, comment vas-tu aujourd\'hui ?',
          durationMs: 2200), isFalse);
      expect(looksHallucinated('Oui', durationMs: 600), isFalse);
      expect(looksHallucinated('I really like eating pasta.',
          durationMs: 1800), isFalse);
      expect(looksHallucinated('こんにちは、元気ですか？', durationMs: 1800), isFalse);
    });

    test('short answers survive the stray-letter rule', () {
      // This is the whole risk of that rule: a call is mostly made of these.
      expect(looksHallucinated('Ça va', durationMs: 700), isFalse);
      expect(looksHallucinated('Non !', durationMs: 500), isFalse);
      expect(looksHallucinated('OK', durationMs: 400), isFalse);
      // Japanese, Chinese, Korean and Thai are exempt from it entirely: a lone
      // character is a word there, and there are no spaces to split on.
      expect(looksHallucinated('はい', durationMs: 500), isFalse);
      expect(looksHallucinated('好', durationMs: 400), isFalse);
      expect(looksHallucinated('네', durationMs: 400), isFalse);
    });

    test('insistence is not a loop', () {
      // Three is a person being firm; four-plus AND dominating the sentence is
      // the decoder giving up.
      expect(looksHallucinated('Non, non, non !', durationMs: 1500), isFalse);
      expect(looksHallucinated('Oui, je viens de le dire, oui.',
          durationMs: 2000), isFalse);
    });
  });
}
