import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/widgets/tap_pad.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('a 24 px button answers up to 44 px without changing size',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      PadTap(
        onTap: () => taps++,
        behavior: HitTestBehavior.opaque,
        child: const SizedBox(width: 24, height: 24),
      ),
    ));
    expect(tester.getSize(find.byType(PadTap)), const Size(24, 24));
    final c = tester.getCenter(find.byType(PadTap));
    await tester.tapAt(c + const Offset(10, 0)); // hors des 24 px, dans les 44
    await tester.tapAt(c + const Offset(0, -10));
    expect(taps, 2);
    await tester.tapAt(c + const Offset(30, 0)); // trop loin
    expect(taps, 2);
  });

  testWidgets('without onTap: no margin, the touch goes through',
      (tester) async {
    var under = 0;
    await tester.pumpWidget(host(
      Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => under++,
            child: const SizedBox(width: 100, height: 100),
          ),
          const PadTap(child: SizedBox(width: 24, height: 24)),
        ],
      ),
    ));
    final c = tester.getCenter(find.byType(PadTap));
    await tester.tapAt(c + const Offset(10, 0));
    expect(under, 1);
  });

  testWidgets('an already large child is not widened', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      PadTap(
        onTap: () => taps++,
        behavior: HitTestBehavior.opaque,
        child: const SizedBox(width: 60, height: 60),
      ),
    ));
    final c = tester.getCenter(find.byType(PadTap));
    await tester.tapAt(c + const Offset(40, 0));
    expect(taps, 0);
  });
}
