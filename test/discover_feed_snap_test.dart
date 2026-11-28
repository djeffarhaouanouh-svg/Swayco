import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/profile_api.dart';
import 'package:livekit_translate/widgets/discover_feed.dart';

RemoteProfile _person(int i) => RemoteProfile(
      id: 'p$i',
      handle: 'p$i',
      displayName: 'Nom$i',
      language: 'fr-FR',
      avatarColor: '',
      avatarUrl: '',
    );

void main() {
  const view = Size(390, 700);
  const bottom = 124.0;

  Future<(ScrollController, List<String>, List<String>)> pump(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = view;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    final opened = <String>[];
    final liked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DiscoverFeed(
          controller: controller,
          entries: [
            for (var i = 0; i < 5; i++)
              (
                profile: _person(i),
                photos: ['https://x.test/$i-a.jpg', 'https://x.test/$i-b.jpg'],
              ),
          ],
          likedIds: const {},
          onToggleLike: (p) => liked.add(p.id),
          onOpenProfile: (p) => opened.add(p.id),
          onSeen: (_) {},
          onScrollMoved: (_, _) {},
          nextAdGap: () => 100,
          footer: const SizedBox(height: 300),
          bottomSpace: bottom + 24,
          maxCardHeight: 430,
        ),
      ),
    ));
    await tester.pump();
    return (controller, opened, liked);
  }

  /// La carte [i] est entière, au milieu, et au-dessus de la barre du bas.
  void expectShown(WidgetTester tester, int i) {
    final box = tester.getRect(find
        .ancestor(
          of: find.text('Nom$i'),
          matching: find.byType(ClipRRect),
        )
        .first);
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.bottom, lessThanOrEqualTo(view.height - bottom));
  }

  testWidgets('un petit geste vers le bas mène à la carte suivante',
      (tester) async {
    final (c, _, _) = await pump(tester);
    expect(c.offset, 0);
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, -80), 600);
    await tester.pumpAndSettle();
    final second = c.offset;
    expect(second, greaterThan(200));
    expectShown(tester, 1);

    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, -80), 600);
    await tester.pumpAndSettle();
    // Une carte de plus, pas davantage (430 de haut + 14 d'espace).
    expect(c.offset - second, closeTo(444, 1));
    expectShown(tester, 2);
  });

  testWidgets('un élan très rapide n’avance que d’une carte', (tester) async {
    final (c, _, _) = await pump(tester);
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, -120), 6000);
    await tester.pumpAndSettle();
    expectShown(tester, 1);
    expect(c.offset, lessThan(600));
  });

  testWidgets('un glissé lent revient ou avance selon la distance',
      (tester) async {
    final (c, _, _) = await pump(tester);
    await tester.timedDrag(find.byType(CustomScrollView),
        const Offset(0, -45), const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(c.offset, 0);
    await tester.timedDrag(find.byType(CustomScrollView),
        const Offset(0, -150), const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expectShown(tester, 1);
  });

  testWidgets('vers le haut, on revient à la première carte', (tester) async {
    final (c, _, _) = await pump(tester);
    await tester.fling(
        find.byType(CustomScrollView), const Offset(0, -80), 600);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 80), 600);
    await tester.pumpAndSettle();
    expect(c.offset, 0);
  });

  testWidgets('un cran de molette = une carte', (tester) async {
    final (c, _, _) = await pump(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    mouse.hover(tester.getCenter(find.text('Nom0')));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    // La suite d'une rafale est ignorée.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pumpAndSettle();
    expectShown(tester, 1);
    expect(c.offset, lessThan(600));
  });

  testWidgets('sous la dernière carte, le défilement est libre',
      (tester) async {
    final (c, _, _) = await pump(tester);
    for (var i = 0; i < 6; i++) {
      await tester.fling(
          find.byType(CustomScrollView), const Offset(0, -120), 900);
      await tester.pumpAndSettle();
    }
    expect(c.offset, closeTo(c.position.maxScrollExtent, 1));
  });

  testWidgets('revenir en haut par le code n’est pas annulé', (tester) async {
    final (c, _, _) = await pump(tester);
    for (var i = 0; i < 3; i++) {
      await tester.fling(
          find.byType(CustomScrollView), const Offset(0, -80), 600);
      await tester.pumpAndSettle();
    }
    c.animateTo(0,
        duration: const Duration(milliseconds: 300), curve: Curves.linear);
    await tester.pumpAndSettle();
    expect(c.offset, 0);
  });

  testWidgets('toucher la photo ouvre le profil, le cœur aime',
      (tester) async {
    final (_, opened, liked) = await pump(tester);
    await tester.tapAt(const Offset(195, 200));
    await tester.pump();
    expect(opened, ['p0']);
    await tester.tap(find.byIcon(Icons.favorite_rounded).first);
    await tester.pump();
    expect(liked, ['p0']);
    expect(opened, ['p0']);
  });

  testWidgets('la rangée de pays qui se range ne fait pas osciller le fil',
      (tester) async {
    tester.view.physicalSize = view;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    var collapsed = false;
    var toggles = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            // La même règle que l'écran Discover.
            void moved(ScrollMetrics m, double delta) {
              if (m.pixels > m.maxScrollExtent) return;
              bool? next;
              if (m.pixels > 40 && delta > 2 && m.maxScrollExtent > 200) {
                next = true;
              } else if (m.pixels < 20 || delta < -8) {
                next = false;
              }
              if (next != null && next != collapsed) {
                toggles++;
                setState(() => collapsed = next!);
              }
            }

            return Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  top: collapsed ? 50 : 140,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DiscoverFeed(
                    controller: controller,
                    entries: [
                      for (var i = 0; i < 5; i++)
                        (profile: _person(i), photos: ['https://x.test/$i.jpg']),
                    ],
                    likedIds: const {},
                    onToggleLike: (_) {},
                    onOpenProfile: (_) {},
                    onSeen: (_) {},
                    onScrollMoved: moved,
                    nextAdGap: () => 100,
                    footer: const SizedBox(height: 300),
                    bottomSpace: bottom + 24,
                    maxCardHeight: 420,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ));
    for (var i = 1; i <= 3; i++) {
      await tester.fling(
          find.byType(CustomScrollView), const Offset(0, -80), 600);
      await tester.pumpAndSettle();
      final card = tester.getRect(find
          .ancestor(
              of: find.text('Nom$i'), matching: find.byType(ClipRRect))
          .first);
      // Petit écran : posée juste au-dessus de la barre du bas, une fois la
      // liste agrandie (haut à 50), et non à l'ancienne place.
      // (la photo est 7 px à l'intérieur du cadre).
      expect(card.bottom, closeTo(view.height - bottom - 4 - 7, 2));
      expect(card.top, greaterThan(50));
    }
    expect(toggles, 1);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 80), 600);
    await tester.pumpAndSettle();
    expect(
      find.text('Nom2'),
      findsOneWidget,
    );
    expect(toggles, 2);
    final back = tester.getRect(find
        .ancestor(of: find.text('Nom2'), matching: find.byType(ClipRRect))
        .first);
    expect(back.top, greaterThanOrEqualTo(140));
    expect(back.bottom, lessThanOrEqualTo(view.height - bottom + 1));
  });

  testWidgets('les photos défilent dans la carte', (tester) async {
    final (c, opened, _) = await pump(tester);
    expect(find.byKey(const ValueKey('dots-p0-0')), findsOneWidget);
    await tester.fling(find.byType(PageView).first, const Offset(-200, 0), 900);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dots-p0-1')), findsOneWidget);
    expect(c.offset, 0);
    expect(opened, isEmpty);
  });
}
