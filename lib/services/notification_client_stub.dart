/// No-op for non-web targets. Native push (FCM) is wired in a separate
/// follow-up: it will replace this stub with a `notification_client_io.dart`
/// using `firebase_messaging` to request permission and register the
/// FCM token, then call NotificationApi.registerFcm.
abstract final class NotificationClient {
  /// Returns true when a transport target was successfully registered
  /// for the current user. Stub always returns false.
  static Future<bool> register(String userId) async => false;

  /// Best-effort cleanup on sign-out. No-op here.
  static Future<void> unregister(String userId) async {}

  /// Diagnostic for the in-app test button — not applicable on web/stub.
  static Future<String> debugInfo() async => 'Non disponible (web).';
}
