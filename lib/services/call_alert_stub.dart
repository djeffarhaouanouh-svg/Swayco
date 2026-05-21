/// No-op implementation used on native targets (mobile / desktop), where
/// incoming-call UX is already handled by the OS / the in-app dialog.
abstract final class CallAlert {
  /// Mirrors the web flag so callers can set it on any platform without
  /// a conditional import. No-op here — native has no in-app sounds.
  static bool soundsEnabled = true;

  static void start({String? callerName}) {}
  static void startDialing({String? calleeName}) {}
  static void stop() {}
}
