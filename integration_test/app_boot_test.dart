// Smoke test — boots the REAL app and asserts it reaches a rendered frame
// without throwing. Catches "crashes on launch / black screen" regressions,
// which have bitten the boot path before (see main.dart's runZonedGuarded
// comments).
//
//   flutter test integration_test/app_boot_test.dart -d <device>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/boot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots and renders without crashing', (tester) async {
    final errors = await bootApp(tester);

    expect(find.byType(MaterialApp), findsOneWidget,
        reason: 'The MaterialApp never mounted — app failed to boot.');
    expect(errors, isEmpty,
        reason: 'Boot threw: ${errors.map((e) => e.exception).join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
