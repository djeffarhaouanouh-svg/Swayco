import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';
import 'package:livekit_translate/widgets/translation_tutorial.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({required VoidCallback onClose, String lang = 'ja'}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 800,
          child: TranslationTutorial(
            peerName: 'Aiko',
            peerLang: lang,
            peerPhotoUrl: '',
            orbBuilder: (ValueListenable<bool> tts, ValueListenable<double> level) =>
                const SizedBox(width: 10, height: 10, key: ValueKey('orb')),
            onClose: onClose,
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    AppStrings.currentBcp47.value = 'fr';
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('annonce un délai réaliste, sans compte à rebours', (tester) async {
    await tester.pumpWidget(_host(onClose: () {}));
    expect(
      find.text(
        'Tu parles, tu patientes 2 à 3 secondes, Aiko reçoit la traduction, tu reparles.',
      ),
      findsOneWidget,
    );
    expect(find.text('Ton écran'), findsOneWidget);
    expect(find.text('Écran de Aiko'), findsOneWidget);
    // Un galet par écran (le vrai galet est fourni par l'appel).
    expect(find.byKey(const ValueKey('orb')), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('les quatre étapes se suivent en boucle', (tester) async {
    await tester.pumpWidget(_host(onClose: () {}));
    // Étape 1 : « Parle normalement » chez moi.
    expect(find.text('Parle normalement'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    // Étape 2 : l'attente, avec le délai estimé.
    expect(find.text('Patiente 2 à 3 secondes…'), findsOneWidget);
    expect(find.text('La traduction arrive…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2300));
    // Étape 3 : l'autre reçoit, dans SA langue (japonais).
    expect(find.text('Aiko a reçu ta traduction'), findsOneWidget);
    expect(find.text('こんにちは！リヨンから来ました。'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2300));
    // Étape 4 : à toi.
    expect(find.text('À toi, tu peux reparler'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2300));
    // Et ça reboucle.
    expect(find.text('Parle normalement'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('se ferme d\'un geste', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_host(onClose: () => closed++));
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.tap(find.text("J'ai compris"));
    expect(closed, 2);
    await tester.pumpWidget(const SizedBox());
  });

  test('ne revient plus une fois vu', () async {
    expect(await TranslationTutorial.shouldShow(), isTrue);
    await TranslationTutorial.markSeen();
    expect(await TranslationTutorial.shouldShow(), isFalse);
  });

  test('les textes existent dans les 12 langues', () {
    const keys = [
      'tuto_tr_title', 'tuto_tr_you', 'tuto_tr_peer', 'tuto_tr_s1', 'tuto_tr_s2',
      'tuto_tr_s3', 'tuto_tr_s4', 'tuto_tr_l1', 'tuto_tr_l2', 'tuto_tr_l3',
      'tuto_tr_l4', 'tuto_tr_p2', 'tuto_tr_p3', 'tuto_tr_sample', 'tuto_tr_ok',
    ];
    for (final code in ['fr', 'en', 'es', 'de', 'it', 'pt', 'pt-BR', 'nl', 'ar', 'ru', 'zh', 'ja', 'ko']) {
      for (final k in keys) {
        final v = AppStrings.tIn(code, k);
        expect(v, isNot(k), reason: '$code / $k manquant');
        expect(v.trim(), isNotEmpty);
      }
    }
  });
}
