// Native (iOS + Android) FCM registration. Picked up by the build via
// the conditional export in `notification_client.dart` on any target
// where `dart:io` is available.
//
// Prereqs (already wired):
//   * `firebase_core` + `firebase_messaging` in pubspec.yaml.
//   * `lib/firebase_options.dart` with the Android + iOS app configs.
//   * `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
//     called in `main.dart` before this class is touched.
//   * `android/settings.gradle.kts` declares `com.google.gms.google-services`.
//   * `android/app/build.gradle.kts` applies it.
//   * `android/app/google-services.json` present.
//   * `ios/Runner/GoogleService-Info.plist` present.
//   * Apple Dev: an APNs Authentication Key uploaded into Firebase
//     Console → Cloud Messaging → Apple app configuration.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_api.dart';
import 'notification_router.dart';

abstract final class NotificationClient {
  /// Notification authorization, normalised to the three states the UI cares
  /// about: `'enabled'` (authorized / provisional), `'undetermined'` (never
  /// asked — safe to show the native prompt), `'denied'` (refused — only the
  /// OS Settings can re-enable). Fail-open to `'enabled'` so a read error
  /// never nags the user with a banner.
  static Future<String> notifStatus() async {
    try {
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      final a = s.authorizationStatus;
      if (a == AuthorizationStatus.authorized ||
          a == AuthorizationStatus.provisional) {
        return 'enabled';
      }
      if (a == AuthorizationStatus.denied) return 'denied';
      return 'undetermined';
    } catch (e) {
      debugPrint('[notify] notifStatus failed: $e');
      return 'enabled';
    }
  }

  /// Boot-time registration that NEVER shows the native prompt: it registers
  /// the FCM token only when permission is already granted, otherwise no-ops.
  /// This stops the cold iOS prompt from being burned at launch before the
  /// user has seen the priming rationale (now shown contextually from the
  /// message list via [NotifEnableFlow]).
  static Future<bool> registerIfAuthorized(String userId) async {
    if (userId.isEmpty) return false;
    final status = await notifStatus();
    if (status != 'enabled') {
      // Still wire tap-routing so a push that does arrive (provisional, or
      // after a later grant from Settings) routes to the right screen.
      unawaited(_wireTapRouting());
      return false;
    }
    return register(userId);
  }

  static Future<bool> register(String userId) async {
    if (userId.isEmpty) return false;
    try {
      final messaging = FirebaseMessaging.instance;
      // Route notification taps to the right screen (cold launch +
      // background tap). Independent of the token registration below.
      unawaited(_wireTapRouting());
      // iOS / web require an explicit permission request. Android <13
      // grants on install; Android 13+ matches the iOS prompt.
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        debugPrint('[notify] permission=${settings.authorizationStatus}');
        return false;
      }

      // Show the banner even while the app is in the FOREGROUND (iOS otherwise
      // silently suppresses it) — so message/call pushes and the in-app test
      // notification are actually visible without backgrounding the app.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // On iOS we need APNs token to be available before FCM hands us
      // a token. getToken() blocks until it is, so this is fine.
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('[notify] empty FCM token');
        return false;
      }
      final platform = Platform.isIOS ? 'ios' : 'android';
      final ok = await NotificationApi.registerFcm(
        userId: userId,
        fcmToken: token,
        platform: platform,
      );

      // Track token rotations — FCM swaps tokens occasionally and any
      // missed update silently drops notifications on that device.
      FirebaseMessaging.instance.onTokenRefresh.listen((fresh) async {
        if (fresh.isEmpty) return;
        await NotificationApi.registerFcm(
          userId: userId,
          fcmToken: fresh,
          platform: platform,
        );
      });

      debugPrint('[notify] registered FCM → ok=$ok platform=$platform');
      return ok;
    } catch (e) {
      debugPrint('[notify] register (firebase) failed: $e');
      return false;
    }
  }

  static bool _tapWired = false;

  /// Wires notification-tap → in-app routing via [NotificationRouter].
  /// Idempotent — safe to call on every [register].
  static Future<void> _wireTapRouting() async {
    if (_tapWired) return;
    _tapWired = true;
    // Background → foreground when the user taps a notification.
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      NotificationRouter.submit(m.data);
    });
    // Cold launch: the app was started by tapping a notification.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) NotificationRouter.submit(initial.data);
  }

  /// Picks up a notification-tap payload that AppDelegate.swift stashed in
  /// UserDefaults when a push COLD-launched the app (fully killed). On iOS,
  /// FirebaseMessaging.getInitialMessage() can miss that case: our plugins
  /// only register once the SceneDelegate connects, which is after
  /// `didFinishLaunchingWithOptions` has already returned — too late for
  /// firebase_messaging to claim the notification-response delegate in time
  /// to see the launch. AppDelegate captures the raw payload synchronously
  /// instead, unconditionally of any plugin timing; this reads it back as
  /// soon as SharedPreferences is available and routes it exactly like a
  /// normal tap. No-op (and harmless) on Android, where getInitialMessage()
  /// already covers the cold-launch case reliably.
  static Future<void> consumeColdLaunchIntent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'pending_notification_launch_data';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      await prefs.remove(key);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      NotificationRouter.submit(data);
    } catch (e) {
      debugPrint('[notify] consumeColdLaunchIntent failed: $e');
    }
  }

  static Future<void> unregister(String userId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await NotificationApi.deleteByFcm(userId: userId, fcmToken: token);
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('[notify] unregister (firebase) failed: $e');
    }
  }

  /// Diagnostic for the in-app "test notification" button: surfaces whether
  /// iOS granted permission and whether an APNs / FCM token was actually
  /// obtained — the usual reasons a regular push never arrives.
  static Future<String> debugInfo() async {
    try {
      final m = FirebaseMessaging.instance;
      final settings = await m.getNotificationSettings();
      var apns = 'AUCUN ❌';
      try {
        if (await m.getAPNSToken() != null) apns = 'OK ✅';
      } catch (_) {}
      var fcm = 'AUCUN ❌';
      try {
        final t = await m.getToken();
        if (t != null && t.isNotEmpty) {
          fcm = 'OK ✅ (${t.substring(0, t.length < 14 ? t.length : 14)}…)';
        }
      } catch (e) {
        fcm = 'erreur: $e';
      }
      // What the NATIVE side (AppDelegate) actually saw — written to
      // UserDefaults under the `flutter.` prefix, so it surfaces the real
      // reason behind "Token APNs: AUCUN" (registration failed? token never
      // arrived? Firebase not ready?).
      var native = '(aucune trace)';
      try {
        final prefs = await SharedPreferences.getInstance();
        // The native side updates this key seconds after launch (token arrival)
        // — reload() bypasses the in-memory cache to read the latest value.
        await prefs.reload();
        native = prefs.getString('apns_native_status') ?? native;
      } catch (_) {}
      return 'Permission: ${settings.authorizationStatus.name}\n'
          'Token APNs: $apns\n'
          'Token FCM: $fcm\n'
          'Natif iOS: $native';
    } catch (e) {
      return 'Erreur: $e';
    }
  }
}
