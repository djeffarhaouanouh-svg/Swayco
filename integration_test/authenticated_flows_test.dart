// Authenticated flow tests — logs in ONCE with a TEST account, then exercises
// the whole signed-in surface: every bottom-nav tab, the Settings screen, and
// the Paywall sheet. One login keeps the run fast (each boot+login is ~30-40s).
//
// Needs a real test account, passed at run time:
//   flutter test integration_test/authenticated_flows_test.dart -d <device> \
//     --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
//     --dart-define=TOKEN_API_BASE=... \
//     --dart-define=TEST_EMAIL=you@example.com --dart-define=TEST_PASSWORD=secret
//
// Without TEST_EMAIL / TEST_PASSWORD the test SKIPS (does not fail), so the full
// `flutter test integration_test` run stays green with no credentials. The
// .\test-all.ps1 helper wires the .env keys + creds for you.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:livekit_translate/screens/chat_screen.dart';
import 'package:livekit_translate/screens/discover_screen.dart';
import 'package:livekit_translate/screens/friend_requests_screen.dart';
import 'package:livekit_translate/screens/login_screen.dart';
import 'package:livekit_translate/screens/paywall_screen.dart';
import 'package:livekit_translate/screens/profile_screen.dart';
import 'package:livekit_translate/screens/root_shell.dart';
import 'package:livekit_translate/screens/settings_screen.dart';
import 'package:livekit_translate/services/app_navigator.dart';
import 'package:livekit_translate/services/app_strings.dart';
import 'package:livekit_translate/services/nav_tab.dart';

import 'helpers/boot.dart';

const _email = String.fromEnvironment('TEST_EMAIL');
const _password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('logs in, every tab + Settings + Paywall render', (tester) async {
    if (_email.isEmpty || _password.isEmpty) {
      markTestSkipped(
          'Set --dart-define=TEST_EMAIL=... and TEST_PASSWORD=... to run the '
          'authenticated flow (see .\\test-all.ps1).');
      return;
    }

    // `errors` keeps accumulating through the whole test: bootApp installs the
    // FlutterError handler and never removes it, so a throw on ANY screen below
    // is captured, not just during boot.
    final errors = await bootApp(tester);

    // --- Log in (a cached session skips the login screen) ---------------------
    if (find.byType(LoginScreen).evaluate().isNotEmpty) {
      await tester.enterText(find.byType(TextField).at(0), _email);
      await tester.enterText(find.byType(TextField).at(1), _password);
      await tester.tap(
          find.widgetWithText(FilledButton, AppStrings.t('login_btn_signin')));
      final reached =
          await pumpUntilFound(tester, find.byType(RootShell), tries: 150);
      expect(reached, isTrue,
          reason: 'Login never reached RootShell — check the test account, '
              'the SUPABASE_* keys, and network reachability.');
    }

    // --- Every bottom-nav tab mounts -----------------------------------------
    final tabs = <int, Type>{
      NavTab.chat: ChatScreen,
      NavTab.discover: DiscoverScreen,
      NavTab.demandes: FriendRequestsScreen,
      NavTab.profile: ProfileScreen,
    };
    for (final entry in tabs.entries) {
      NavTab.select(entry.key);
      final ok =
          await pumpUntilFound(tester, find.byType(entry.value), tries: 50);
      expect(ok, isTrue,
          reason: 'Tab ${entry.key} (${entry.value}) never rendered.');
    }

    // --- Settings screen renders ---------------------------------------------
    // Push it through the app's real root navigator (same key the app uses),
    // then pop back so the Paywall opens over the shell, not over Settings.
    rootNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    final settingsOk =
        await pumpUntilFound(tester, find.byType(SettingsScreen), tries: 50);
    expect(settingsOk, isTrue, reason: 'SettingsScreen never rendered.');
    rootNavigatorKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 300));

    // --- Paywall sheet renders -----------------------------------------------
    // showPaywallSheet shows a modal bottom sheet; assert its headline appears.
    showPaywallSheet(rootNavigatorKey.currentContext!);
    final paywallOk = await pumpUntilFound(
        tester, find.text(AppStrings.t('paywall_headline')),
        tries: 50);
    expect(paywallOk, isTrue, reason: 'Paywall sheet never rendered.');

    // --- No framework error anywhere in the flow ------------------------------
    expect(errors, isEmpty,
        reason: 'A screen threw during the flow: '
            '${errors.map((e) => e.exception).join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
