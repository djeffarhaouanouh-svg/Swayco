import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/app_strings.dart';
import 'package:livekit_translate/swayco/realtime_translation_port.dart';
import 'package:livekit_translate/widgets/translation_step_caption.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    AppStrings.currentBcp47.value = 'fr';
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('le texte sous le galet suit ce que je fais', (tester) async {
    final voice = ValueNotifier<double>(0);
    final lines = ValueNotifier<SpokenLine>(const SpokenLine(seq: 0, text: ''));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: TranslationStepCaption(
            peerName: 'Aiko',
            myVoice: voice,
            myLines: lines,
          ),
        ),
      ),
    ));
    expect(find.text('Parle normalement'), findsOneWidget);

    voice.value = 0.3;
    await tester.pump();
    voice.value = 0;
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Patiente 2 à 3 secondes…'), findsOneWidget);

    lines.value = const SpokenLine(seq: 1, text: 'Salut', translated: 'こんにちは');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Aiko a reçu ta traduction'), findsOneWidget);
    expect(await TranslationStepCaption.shouldShow(), isFalse);

    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('À toi, tu peux reparler'), findsOneWidget);

    // Une phrase qui n'est pas partie : en rouge.
    lines.value = const SpokenLine(seq: 2, text: 'euh', delivered: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final red = tester.widget<Text>(find.text('Traduction non envoyée'));
    expect(red.style?.color, const Color(0xFFFF4D4D));

    await tester.pumpWidget(const SizedBox());
  });
}
