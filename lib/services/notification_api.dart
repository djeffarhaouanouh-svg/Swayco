import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// CRUD over `public.notification_targets` — the rows the backend reads
/// to decide where to fan out a push when an event happens.
///
/// Two transport surfaces share this table:
///   * Web Push (RFC 8030) — endpoint + p256dh + auth keys, registered
///     from a Service Worker via PushManager.subscribe.
///   * Firebase Cloud Messaging — a single token string per device,
///     refreshed automatically by the firebase_messaging SDK.
///
/// The wrappers here are intentionally thin: the platform-specific
/// registration (asking permission, getting the actual subscription /
/// token) lives in `notification_client.dart` (web stub vs. native
/// stub via conditional import).
abstract final class NotificationApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Upsert the current user's Web Push subscription. Idempotent on
  /// (user_id, endpoint) — calling this every app open is safe and
  /// just bumps `updated_at`.
  static Future<bool> registerWebPush({
    required String userId,
    required String endpoint,
    required String p256dh,
    required String auth,
    String? userAgent,
  }) async {
    if (!isSupabaseReady) return false;
    if (userId.isEmpty || endpoint.isEmpty) return false;
    try {
      await _c.from('notification_targets').upsert(
        {
          'user_id': userId,
          'platform': 'web',
          'endpoint': endpoint,
          'p256dh': p256dh,
          'auth_key': auth,
          'user_agent': ?userAgent,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,endpoint',
      );
      return true;
    } catch (e) {
      debugPrint('NotificationApi.registerWebPush failed: $e');
      return false;
    }
  }

  /// Upsert a Firebase Cloud Messaging token. Called every time the
  /// FCM SDK reports a new token (initial login + automatic rotations).
  static Future<bool> registerFcm({
    required String userId,
    required String fcmToken,
    required String platform, // 'ios' | 'android'
    String? userAgent,
  }) async {
    if (!isSupabaseReady) return false;
    if (userId.isEmpty || fcmToken.isEmpty) return false;
    if (platform != 'ios' && platform != 'android') return false;
    try {
      await _c.from('notification_targets').upsert(
        {
          'user_id': userId,
          'platform': platform,
          'fcm_token': fcmToken,
          'user_agent': ?userAgent,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,fcm_token',
      );
      return true;
    } catch (e) {
      debugPrint('NotificationApi.registerFcm failed: $e');
      return false;
    }
  }

  /// Upsert an iOS PushKit VoIP token (platform `ios_voip`). This is a
  /// separate target from the regular FCM token and is what the backend
  /// pushes to so CallKit can ring full-screen for an incoming call.
  static Future<bool> registerVoip({
    required String userId,
    required String voipToken,
  }) async {
    if (!isSupabaseReady) return false;
    if (userId.isEmpty || voipToken.isEmpty) return false;
    try {
      await _c.from('notification_targets').upsert(
        {
          'user_id': userId,
          'platform': 'ios_voip',
          'fcm_token': voipToken,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,fcm_token',
      );
      return true;
    } catch (e) {
      debugPrint('NotificationApi.registerVoip failed: $e');
      return false;
    }
  }

  /// Drop a single transport target — used on sign-out or when the
  /// browser/native subscription expires and we replace it.
  static Future<void> deleteByEndpoint({
    required String userId,
    required String endpoint,
  }) async {
    if (!isSupabaseReady || userId.isEmpty || endpoint.isEmpty) return;
    try {
      await _c
          .from('notification_targets')
          .delete()
          .eq('user_id', userId)
          .eq('endpoint', endpoint);
    } catch (e) {
      debugPrint('NotificationApi.deleteByEndpoint failed: $e');
    }
  }

  static Future<void> deleteByFcm({
    required String userId,
    required String fcmToken,
  }) async {
    if (!isSupabaseReady || userId.isEmpty || fcmToken.isEmpty) return;
    try {
      await _c
          .from('notification_targets')
          .delete()
          .eq('user_id', userId)
          .eq('fcm_token', fcmToken);
    } catch (e) {
      debugPrint('NotificationApi.deleteByFcm failed: $e');
    }
  }
}
