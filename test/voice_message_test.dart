import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/voice_recorder.dart';
import 'package:livekit_translate/services/voice_wave.dart';
import 'package:livekit_translate/widgets/voice_note_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('voiceBars', () {
    test('la même onde pour le même message, sur tous les téléphones', () {
      expect(voiceBars('msg-123'), voiceBars('msg-123'));
    });

    test('deux messages n\'ont pas la même onde', () {
      expect(voiceBars('msg-123'), isNot(voiceBars('msg-456')));
    });

    test('26 barres, entre 0 et 1, bords plus bas que le milieu', () {
      for (final id in ['a', 'msg-123', 'b7c0e3d2-9f41-4a77-8c3e-1d2f5a6b7c8d']) {
        final bars = voiceBars(id);
        expect(bars.length, 26);
        expect(bars.every((v) => v >= 0 && v <= 1), isTrue);
        // L'enveloppe en cloche : les bords sont bien sous la moyenne du milieu.
        final edge = (bars.first + bars.last) / 2;
        final mid = bars.sublist(8, 18).reduce((a, b) => a + b) / 10;
        expect(edge, lessThan(mid), reason: id);
      }
    });
  });

  test('les durées : m:ss au repos, mm:ss à l\'enregistrement', () {
    expect(voiceClock(const Duration(seconds: 7)), '0:07');
    expect(voiceClock(const Duration(seconds: 83)), '1:23');
    expect(voiceTimer(const Duration(seconds: 7)), '00:07');
    expect(voiceTimer(const Duration(seconds: 60)), '01:00');
  });

  test('niveau : -45 dB (silence) à 0 dB, borné à 0..1', () {
    expect(voiceLevelFromDb(-60), 0);
    expect(voiceLevelFromDb(-45), 0);
    expect(voiceLevelFromDb(-22.5), closeTo(0.5, 1e-9));
    expect(voiceLevelFromDb(0), 1);
    expect(voiceLevelFromDb(6), 1);
  });

  test('le vrai format se lit dans le fichier (MP4 de Safari ≠ WebM de Chrome)', () {
    expect(sniffAudioContainer([0x1A, 0x45, 0xDF, 0xA3, 1, 2])?.ext, 'webm');
    expect(
      sniffAudioContainer([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34])?.contentType,
      'audio/mp4',
    );
    expect(sniffAudioContainer([0x4F, 0x67, 0x67, 0x53])?.ext, 'ogg');
    expect(sniffAudioContainer([1, 2, 3]), isNull);
  });

  test('les limites : 1 s minimum, 60 s maximum', () {
    expect(kVoiceMinMs, 1000);
    expect(kVoiceMaxMs, 60000);
  });

  group('VoiceNotePlayer', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool mine,
      int durationMs = 27000,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 230,
                child: VoiceNotePlayer(
                  // Une bulle par message : une clé neuve = un état neuf.
                  key: UniqueKey(),
                  url: 'https://example.invalid/v.m4a',
                  color: Colors.white,
                  messageId: 'msg-123',
                  mine: mine,
                  durationMs: durationMs,
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('affiche la durée du message avant toute lecture', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester, mine: true);
      await tester.pump();
      expect(find.text('0:27'), findsOneWidget);
    });

    testWidgets('vocal reçu non écouté : le point cyan ; écouté ou envoyé : rien',
        (tester) async {
      bool hasDot() => find
          .byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color == kVoiceUnheardDot,
          )
          .evaluate()
          .isNotEmpty;

      SharedPreferences.setMockInitialValues({});
      await pump(tester, mine: false);
      await tester.pumpAndSettle();
      expect(hasDot(), isTrue);

      SharedPreferences.setMockInitialValues({'voice_heard_msg-123': true});
      await pump(tester, mine: false);
      await tester.pumpAndSettle();
      expect(hasDot(), isFalse);

      SharedPreferences.setMockInitialValues({});
      await pump(tester, mine: true);
      await tester.pumpAndSettle();
      expect(hasDot(), isFalse);
    });

    testWidgets('zone tactile du bouton lecture : 44 px au moins', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester, mine: false);
      await tester.pump();
      final btn = tester.getSize(find.byIcon(Icons.play_arrow_rounded).first);
      expect(btn.width, greaterThan(0));
      final hit = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.play_arrow_rounded),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(hit.width, greaterThanOrEqualTo(44));
      expect(hit.height, greaterThanOrEqualTo(44));
    });
  });
}
