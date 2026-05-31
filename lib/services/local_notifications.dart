import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// On-device notification presentation. FCM only carries the data — this
/// is what actually rings / shows the banner once a push arrives.
///
/// Two channels:
///   * `calls`    — full-screen intent, ringtone + vibration. Backs the
///                  WhatsApp-style incoming-call screen when the app is
///                  backgrounded or killed.
///   * `messages` — standard heads-up banner for chat / friend / like.
///
/// [ensureReady] is idempotent and isolate-safe: it is called from both
/// the main isolate (foreground display) and the FCM background isolate
/// (each isolate gets its own plugin instance and channel registration).
abstract final class LocalNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Stable id for the single ringing-call notification so we can cancel
  /// it the moment the call is answered / declined / cancelled.
  static const int callNotificationId = 424242;

  static final AndroidNotificationChannel _callsChannel =
      const AndroidNotificationChannel(
    'calls',
    'Appels',
    description: 'Appels entrants',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static final AndroidNotificationChannel _messagesChannel =
      const AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'Messages, demandes et likes',
    importance: Importance.high,
  );

  static Future<void> ensureReady() async {
    // flutter_local_notifications has no web implementation; web push is
    // disabled anyway (see notification_client.dart).
    if (kIsWeb || _ready) return;
    const android = AndroidInitializationSettings('ic_notification');
    const darwin = DarwinInitializationSettings(
      // firebase_messaging already prompts for permission on iOS — don't
      // double-ask here.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
    );
    final android_ = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android_ != null) {
      await android_.createNotificationChannel(_callsChannel);
      await android_.createNotificationChannel(_messagesChannel);
    }
    _ready = true;
  }

  /// Full-screen ringing incoming-call notification (WhatsApp-style).
  static Future<void> showIncomingCall({
    required String title,
    String? body,
  }) async {
    if (kIsWeb) return;
    await ensureReady();
    final android = AndroidNotificationDetails(
      _callsChannel.id,
      _callsChannel.name,
      channelDescription: _callsChannel.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.call,
      // The whole point: launch a full-screen activity over the lock
      // screen instead of a small heads-up banner.
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      visibility: NotificationVisibility.public,
      ticker: title,
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );
    await _plugin.show(
      callNotificationId,
      title,
      body == null || body.isEmpty ? '📞 Appel entrant' : body,
      NotificationDetails(android: android, iOS: darwin),
      payload: 'incoming_call',
    );
  }

  /// Dismiss the ringing-call notification.
  static Future<void> cancelIncomingCall() async {
    if (kIsWeb) return;
    await ensureReady();
    await _plugin.cancel(callNotificationId);
  }

  /// Standard heads-up banner for a non-call event (chat / friend / like).
  static Future<void> showMessage({
    required int id,
    required String title,
    String? body,
  }) async {
    if (kIsWeb) return;
    await ensureReady();
    final android = AndroidNotificationDetails(
      _messagesChannel.id,
      _messagesChannel.name,
      channelDescription: _messagesChannel.description,
      importance: Importance.high,
      priority: Priority.high,
    );
    const darwin = DarwinNotificationDetails();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: darwin),
    );
  }
}
