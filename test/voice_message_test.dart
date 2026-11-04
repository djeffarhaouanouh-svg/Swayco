import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/voice_clip.dart';
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

  test('l\'info « prêt à lire » de l\'iPhone n\'est PAS une erreur du lecteur', () {
    // Le message exact vu dans l'app (capture) : il passait pour un échec.
    expect(
      isRealPlayerError(
        'player status: AVPlayerItemStatus(rawValue: 1), change: '
        'NSKeyValueObservedChange<AVPlayerItemStatus>(kind: __C.NSKeyValueChange, '
        'newValue: nil, oldValue: nil, indexes: nil, isPrior: false)',
      ),
      isFalse,
    );
    expect(isRealPlayerError('Failed to set source'), isTrue);
    expect(isRealPlayerError('AVPlayerItem error: -11800'), isTrue);
  });

  group('VoiceNotePlayer avec un faux lecteur', () {
    late _FakeClip clip;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      clip = _FakeClip();
      VoiceNotePlayer.clipFactory = () => clip;
    });
    tearDown(() => VoiceNotePlayer.clipFactory = createVoiceClip);

    Future<void> pumpPlayer(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 230,
                  child: VoiceNotePlayer(
                    key: UniqueKey(),
                    url: 'https://example.invalid/v.m4a',
                    color: Colors.white,
                    messageId: 'm1',
                    mine: false,
                    durationMs: 8000,
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('toucher lecture : pause pendant la lecture, lecture à la fin',
        (tester) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(clip.played, ['https://example.invalid/v.m4a']);
      clip.emitPlaying.add(true);
      await tester.pump();      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      clip.emitCompleted.add(null);
      clip.emitPlaying.add(false);
      await tester.pump();      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('un message de log banal ne met pas le bouton en erreur',
        (tester) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      clip.emitPlaying.add(true);
      await tester.pump();      await tester.pump(const Duration(milliseconds: 50));
      // Le lecteur mobile filtre déjà ses logs : rien n'arrive dans `errors`.
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });

    testWidgets('une vraie erreur : bouton en erreur, retouchable', (tester) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      clip.emitError.add('lecture impossible (code 3)');
      await tester.pump();      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      // Un nouvel appui relance la lecture.
      await tester.tap(find.byIcon(Icons.error_outline_rounded));
      await tester.pump();
      expect(clip.played.length, 2);
    });

    testWidgets('play() qui lève : bouton en erreur', (tester) async {
      clip.failPlay = true;
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('lecture puis pause puis reprise', (tester) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      clip.emitPlaying.add(true);
      clip.emitPosition.add(const Duration(seconds: 3));
      await tester.pump();      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      expect(clip.pauses, 1);
      clip.emitPlaying.add(false);
      await tester.pump();      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(clip.resumes, 1);
    });
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

/// Un faux lecteur : le test pilote lui-même ce que le vrai enverrait.
class _FakeClip implements VoiceClip {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();

  /// Ce que le test « fait émettre » au lecteur.
  StreamSink<bool> get emitPlaying => _playing.sink;
  StreamSink<Duration> get emitPosition => _position.sink;
  StreamSink<void> get emitCompleted => _completed.sink;
  StreamSink<String> get emitError => _errors.sink;

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;

  final played = <String>[];
  int pauses = 0;
  int resumes = 0;
  bool failPlay = false;

  @override
  Future<void> play(String url) async {
    played.add(url);
    if (failPlay) throw StateError('refusé');
  }

  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> resume() async => resumes++;
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}