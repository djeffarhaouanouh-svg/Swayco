// Login screen tests — exercise the unauthenticated surface (field rendering,
// client-side validation, sign-in/sign-up toggle). These need NO test account
// and NO network: every assertion is reached before any Supabase call.
//
// Expected strings are read via AppStrings.t() at runtime so the test matches
// whatever locale the app booted in (no hard-coded French/English).
//
//   flutter test integration_test/login_test.dart -d <device>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:livekit_translate/screens/login_screen.dart';
import 'package:livekit_translate/services/app_strings.dart';

import 'helpers/boot.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // A cached session from a previous run skips login → the shell renders
  // instead and there is nothing to assert. Bail out cleanly in that case.
  bool onLogin() => find.byType(LoginScreen).evaluate().isNotEmpty;

  group('Login screen', () {
    testWidgets('shows email + password fields with no boot error',
        (tester) async {
      final errors = await bootApp(tester);
      if (!onLogin()) {
        markTestSkipped('Already authenticated (cached session).');
        return;
      }
      expect(find.byType(TextField), findsNWidgets(2));
      expect(errors, isEmpty,
          reason: 'Boot threw: ${errors.map((e) => e.exception).join('\n')}');
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('invalid email shows the email validation error',
        (tester) async {
      await bootApp(tester);
      if (!onLogin()) {
        markTestSkipped('Already authenticated (cached session).');
        return;
      }
      await tester.enterText(find.byType(TextField).at(0), 'not-an-email');
      await tester.pump();
      await tester.tap(
          find.widgetWithText(FilledButton, AppStrings.t('login_btn_signin')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(AppStrings.t('login_err_email')), findsOneWidget);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('valid email but short password shows the password error',
        (tester) async {
      await bootApp(tester);
      if (!onLogin()) {
        markTestSkipped('Already authenticated (cached session).');
        return;
      }
      await tester.enterText(find.byType(TextField).at(0), 'test@example.com');
      await tester.enterText(find.byType(TextField).at(1), '123'); // < 6 chars
      await tester.pump();
      await tester.tap(
          find.widgetWithText(FilledButton, AppStrings.t('login_btn_signin')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(AppStrings.t('login_err_password')), findsOneWidget);
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('toggling to sign-up switches the title', (tester) async {
      await bootApp(tester);
      if (!onLogin()) {
        markTestSkipped('Already authenticated (cached session).');
        return;
      }
      expect(find.text(AppStrings.t('login_title_signin')), findsOneWidget);
      await tester.tap(
          find.widgetWithText(TextButton, AppStrings.t('login_btn_signup')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(AppStrings.t('login_title_signup')), findsOneWidget);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
