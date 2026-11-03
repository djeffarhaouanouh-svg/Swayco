import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/nav_chrome.dart';
import 'package:livekit_translate/services/nav_tab.dart';
import 'package:livekit_translate/widgets/nav_auto_hide.dart';

void main() {
  setUp(() {
    NavChrome.show();
    NavTab.index.value = NavTab.chat;
  });

  group('NavChrome', () {
    test('hideAuto : cachée ET marquée automatique (la poignée s\'affiche)', () {
      NavChrome.hideAuto();
      expect(NavChrome.hidden.value, isTrue);
      expect(NavChrome.autoHidden.value, isTrue);
    });

    test('hide() (panneau d\'infos) : cachée, SANS poignée', () {
      NavChrome.hide();
      expect(NavChrome.hidden.value, isTrue);
      expect(NavChrome.autoHidden.value, isFalse);
    });

    test('hideAuto ne fait rien quand le panneau d\'infos l\'a déjà cachée', () {
      NavChrome.hide();
      NavChrome.hideAuto();
      expect(NavChrome.autoHidden.value, isFalse);
    });

    test('hide() pendant un rangement automatique : plus de poignée', () {
      NavChrome.hideAuto();
      NavChrome.hide();
      expect(NavChrome.hidden.value, isTrue);
      expect(NavChrome.autoHidden.value, isFalse);
    });

    test('show() remet tout', () {
      NavChrome.hideAuto();
      NavChrome.show();
      expect(NavChrome.hidden.value, isFalse);
      expect(NavChrome.autoHidden.value, isFalse);
    });

    testWidgets('showAfter : revient après le délai, un nouveau hideAuto l\'annule',
        (tester) async {
      NavChrome.hideAuto();
      NavChrome.showAfter(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 800));
      expect(NavChrome.hidden.value, isTrue);
      // Un nouveau rangement avant l'échéance annule le retour.
      NavChrome.hideAuto();
      await tester.pump(const Duration(milliseconds: 500));
      expect(NavChrome.hidden.value, isTrue);
      NavChrome.showAfter(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(NavChrome.hidden.value, isFalse);
    });

    testWidgets('showAfter ne rend pas une barre cachée par le panneau d\'infos',
        (tester) async {
      NavChrome.hide();
      NavChrome.showAfter(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(NavChrome.hidden.value, isTrue);
    });
  });

  group('NavAutoHide', () {
    Future<ScrollController> pump(WidgetTester tester, {int tab = NavTab.chat}) async {
      final ctl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: NavAutoHide(
            tab: tab,
            child: ListView.builder(
              controller: ctl,
              itemCount: 60,
              itemBuilder: (_, i) => SizedBox(height: 80, child: Text('ligne $i')),
            ),
          ),
        ),
      );
      return ctl;
    }

    testWidgets('défiler range la barre ; 0,9 s après l\'arrêt elle revient',
        (tester) async {
      await pump(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
      expect(NavChrome.hidden.value, isTrue);
      expect(NavChrome.autoHidden.value, isTrue);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(NavChrome.hidden.value, isFalse);
    });

    testWidgets('revenir tout en haut remet la barre', (tester) async {
      final ctl = await pump(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
      expect(NavChrome.autoHidden.value, isTrue);
      ctl.jumpTo(0);
      await tester.pump();
      // jumpTo ne notifie pas un « update » avec delta : on simule le défilement
      // vers le haut jusqu'au bord.
      await tester.drag(find.byType(ListView), const Offset(0, 40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(NavChrome.hidden.value, isFalse);
    });

    testWidgets('un autre onglet affiché : le défilement ne touche pas la barre',
        (tester) async {
      NavTab.index.value = NavTab.discover;
      await pump(tester, tab: NavTab.chat);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(NavChrome.hidden.value, isFalse);
    });

    testWidgets('le rebond au-dessus du haut (tirer pour rafraîchir) ne cache rien',
        (tester) async {
      await pump(tester);
      // On est tout en haut : tirer vers le bas ne fait que rebondir.
      await tester.drag(find.byType(ListView), const Offset(0, 120));
      await tester.pump();
      expect(NavChrome.hidden.value, isFalse);
    });
  });
}
