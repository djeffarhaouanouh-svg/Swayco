import 'package:flutter/foundation.dart';

/// Boot-time readiness signal for the splash.
///
/// The boot splash stays up until the landing screen's *content* is actually
/// loaded — not just until auth/bootstrap finishes. [homeReady] is flipped:
///  • by the Discover feed once its first load completes (success, empty or
///    timeout), since Discover is the authed landing tab, and
///  • immediately by `main.dart` for landings with no heavy content (guest
///    join, login, onboarding).
///
/// One-shot: once true it stays true, so later sign-in / sign-out navigations
/// never re-show the boot splash.
class AppBoot {
  AppBoot._();

  static final ValueNotifier<bool> homeReady = ValueNotifier<bool>(false);

  static void markHomeReady() {
    if (!homeReady.value) homeReady.value = true;
  }
}
