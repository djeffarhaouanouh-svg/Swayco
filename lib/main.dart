// MINIMAL BISECTION BUILD — temporarily replaces the real Swayco main.
// Builds with the same flutter build command as usual; nothing fancy.
//
// Outcome we're after:
//   * Red screen visible on the device → Flutter renders fine on this
//     install, so the black screen of the real main.dart comes from
//     something the app does (a plugin init, a widget, a timing race).
//     The real main.dart is preserved in git history and is restored
//     in the next commit once the diagnosis lands.
//   * Still black on the device → Flutter itself cannot render on this
//     install, regardless of what Dart code runs. The bug is in the
//     project setup (Xcode build, signing, Gradle, native deps) and
//     no amount of editing main.dart would have fixed it.
//
// The Diag ping with the real MediaQuery dimensions tells us — from
// Railway alone — which case we're in even before the user describes
// the screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'services/diag.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Diag.bind().timeout(const Duration(seconds: 2));
  } catch (_) {}
  unawaited(Diag.ping('minimal-main-start'));
  runApp(const _MinimalApp());
  unawaited(Diag.ping('minimal-runapp-done'));
}

class _MinimalApp extends StatelessWidget {
  const _MinimalApp();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final view =
            WidgetsBinding.instance.platformDispatcher.views.first;
        final mq = MediaQueryData.fromView(view);
        unawaited(Diag.ping('minimal-first-frame',
            note: 'w=${mq.size.width.toStringAsFixed(1)} '
                'h=${mq.size.height.toStringAsFixed(1)} '
                'dpr=${mq.devicePixelRatio.toStringAsFixed(2)}'));
      } catch (e, s) {
        Diag.error('minimal-first-frame-fail', e, s);
      }
    });
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(color: Color(0xFFFF0000)),
    );
  }
}
