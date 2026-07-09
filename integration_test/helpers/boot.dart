// Shared helpers for the integration_test suite.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:livekit_translate/main.dart' as app;

/// Boots the REAL production app (the same `main()` that ships) and pumps it
/// past the splash. Returns the framework errors captured during boot — an
/// empty list means a clean boot (no crash / black screen).
///
/// `main()` wraps its boot in `runZonedGuarded` and awaits several plugin
/// inits, so it can take a few seconds. We bound it with a hard timeout: on an
/// emulator without API keys some platform-channel inits never fully settle,
/// and an unbounded `await main()` would hang the whole test (12-min default
/// timeout). Pumping FIXED frames afterwards (never `pumpAndSettle` — the
/// Lottie splash animates forever) clears the splash and lands the first real
/// screen.
Future<List<FlutterErrorDetails>> bootApp(WidgetTester tester) async {
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    previousOnError?.call(details);
  };

  try {
    await app.main().timeout(const Duration(seconds: 30));
  } on Exception catch (e) {
    debugPrint('bootApp: main() did not settle in 30s: $e');
  }

  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return errors;
}

/// Pumps in short fixed steps until [finder] matches at least one widget, or
/// [tries] steps elapse. Returns whether it matched. Never uses
/// `pumpAndSettle`, so it is safe with continuous animations / pending timers.
Future<bool> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int tries = 80,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < tries; i++) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(step);
  }
  return finder.evaluate().isNotEmpty;
}
