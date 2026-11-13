import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';
import 'package:livekit_translate/swayco/realtime_translation_port.dart';
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

  testWidgets('branché sur l\'appel : les étapes suivent ce que je fais',
      (tester) async {
    final voice = ValueNotifier<double>(0);
    final lines = ValueNotifier<SpokenLine>(const SpokenLine(seq: 0, text: ''));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 800,
          child: TranslationTutorial(
            peerName: 'Aiko',
            peerLang: 'ja',
            peerPhotoUrl: '',
            myVoice: voice,
            myLines: lines,
            orbBuilder: (tts, level) => const SizedBox(width: 10, height: 10),
            onClose: () {},
          ),
        ),
      ),
    ));
    // Au repos : on m'invite à parler, rien ne bouge tout seul.
    expect(find.text('Parle normalement'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Parle normalement'), findsOneWidget);
    expect(find.text('Patiente 2 à 3 secondes…'), findsNothing);

    // Je parle : badge « Tu parles » sur ma vignette.
    voice.value = 0.3;
    await tester.pump();
    expect(find.text('Tu parles'), findsWidgets);

    // Je me tais : après un court silence, « Patiente ».
    voice.value = 0;
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Patiente 2 à 3 secondes…'), findsOneWidget);
    expect(find.text('La traduction arrive…'), findsOneWidget);

    // Ma phrase part : MA vraie phrase chez moi, SA traduction chez l'autre.
    lines.value = const SpokenLine(
      seq: 1,
      text: 'Je suis à Nantes',
      translated: 'ナントにいます',
    );
    await tester.pump();
    expect(find.text('Aiko a reçu ta traduction'), findsOneWidget);
    expect(find.text('Je suis à Nantes'), findsOneWidget);
    expect(find.text('ナントにいます'), findsOneWidget);

    // Puis « à toi ».
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('À toi, tu peux reparler'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Parle normalement'), findsOneWidget);

    // Une phrase qui n'a pas pu partir ne fait pas croire qu'elle est arrivée.
    voice.value = 0.3;
    await tester.pump();
    voice.value = 0;
    await tester.pump(const Duration(milliseconds: 450));
    lines.value = const SpokenLine(seq: 2, text: 'euh', delivered: false);
    await tester.pump();
    expect(find.text('Aiko a reçu ta traduction'), findsNothing);
    // Dit en rouge, puis retour à l'invitation à parler.
    expect(find.text('Traduction non envoyée'), findsOneWidget);
    final red = tester.widget<Text>(find.text('Traduction non envoyée'));
    expect(red.style?.color, const Color(0xFFFF4D4D));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Traduction non envoyée'), findsNothing);
    expect(find.text('Parle normalement'), findsOneWidget);

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
      'tuto_tr_fail',
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
