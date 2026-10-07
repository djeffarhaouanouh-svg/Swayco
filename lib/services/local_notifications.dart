import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

import 'notification_router.dart';

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

  /// Stable id for the "you didn't finish onboarding" reminder — one at a
  /// time, replaced/cancelled by id.
  static const int onboardingReminderId = 424243;

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
      // Toucher une notification dessinee par l'app (photo en grande icone) :
      // meme routage que celles dessinees par le systeme.
      onDidReceiveNotificationResponse: (r) => _route(r.payload),
    );
    final android_ = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android_ != null) {
      await android_.createNotificationChannel(_callsChannel);
      await android_.createNotificationChannel(_messagesChannel);
      // Android 13+ : POST_NOTIFICATIONS runtime grant (FCM also asks, but
      // this covers the case where push is off yet calls still need to ring).
      try {
        await android_.requestNotificationsPermission();
      } catch (_) {/* older Android: granted at install */}
      // Android 14+ (API 34): a full-screen-intent notification is downgraded
      // to a heads-up banner unless this special permission is granted. This
      // is what makes the incoming call actually take over the screen
      // (WhatsApp-style) instead of a small banner.
      try {
        await android_.requestFullScreenIntentPermission();
      } catch (_) {/* older Android: not required */}
    }
    _ready = true;
  }

  /// Remet au routeur le `data` de FCM porte par une notification locale.
  /// Les charges non JSON (« incoming_call »…) sont ignorees.
  static void _route(String? payload) {
    if (payload == null || !payload.startsWith('{')) return;
    try {
      final data = jsonDecode(payload);
      if (data is Map) NotificationRouter.submit(Map<String, dynamic>.from(data));
    } catch (_) {}
  }

  /// Demarrage a froid : l'app a ete lancee en touchant une de NOS
  /// notifications (le systeme ne la connait pas comme message FCM).
  static Future<void> consumeLaunchPayload() async {
    if (kIsWeb) return;
    try {
      await ensureReady();
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d?.didNotificationLaunchApp ?? false) {
        _route(d?.notificationResponse?.payload);
      }
    } catch (_) {}
  }

  /// Download the actor's photo for the Android large icon (circular avatar
  /// next to the title, Instagram / Snap style). The status-bar glyph stays
  /// [ic_notification] — Android requires a white silhouette there.
  static Future<ByteArrayAndroidBitmap?> _androidAvatar(String? url) async {
    final u = (url ?? '').trim();
    if (u.isEmpty || !u.startsWith('https://')) return null;
    try {
      final res = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      if (res.bodyBytes.length > 1024 * 1024) return null;
      return ByteArrayAndroidBitmap(res.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  /// Full-screen ringing incoming-call notification (WhatsApp-style).
  static Future<void> showIncomingCall({
    required String title,
    String? body,
    String? imageUrl,
  }) async {
    if (kIsWeb) return;
    await ensureReady();
    final avatar = await _androidAvatar(imageUrl);
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
      largeIcon: avatar,
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );
    await _plugin.show(
      callNotificationId,
      title,
      // Anglais en repli, comme le titre : le corps arrive déjà traduit dans la
      // langue du destinataire, et ceci ne sert que s'il manque. Repris mot
      // pour mot de `push_incoming_call_body` côté anglais.
      body == null || body.isEmpty ? '📞 Incoming call' : body,
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

  /// Schedule the "you haven't finished setting up your account" reminder to
  /// fire [after] from now (default 5 min) — WhatsApp-style. Best-effort:
  /// no-ops on web and, silently, when notifications aren't permitted.
  /// Scheduling again replaces the pending one (fixed [onboardingReminderId]),
  /// so calling this every time the app is backgrounded mid-onboarding just
  /// pushes the reminder back.
  static Future<void> scheduleOnboardingReminder({
    required String title,
    required String body,
    Duration after = const Duration(minutes: 5),
  }) async {
    if (kIsWeb) return;
    await ensureReady();
    // An absolute instant — `after` from now. `tz.UTC` needs no timezone-db
    // init, and "now + Duration" is the same moment in any zone.
    final when = tz.TZDateTime.now(tz.UTC).add(after);
    final android = AndroidNotificationDetails(
      _messagesChannel.id,
      _messagesChannel.name,
      channelDescription: _messagesChannel.description,
      importance: Importance.high,
      priority: Priority.high,
    );
    const darwin = DarwinNotificationDetails();
    try {
      await _plugin.zonedSchedule(
        onboardingReminderId,
        title,
        body,
        when,
        NotificationDetails(android: android, iOS: darwin),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: 'onboarding_reminder',
      );
    } catch (_) {
      // e.g. exact-alarm permission quirks on some OEMs — the reminder is a
      // nice-to-have, never worth surfacing an error for.
    }
  }

  /// Stable id du rappel « il te reste 1 message special ».
  static const int specialLeftId = 424244;

  /// Programme, dans [after], le rappel « il te reste 1 message special » (le
  /// dernier). Reprogrammer remplace le precedent (meme id).
  static Future<void> scheduleSpecialLeftReminder({
    required String title,
    required String body,
    Duration after = const Duration(hours: 3),
  }) async {
    if (kIsWeb) return;
    await ensureReady();
    final when = tz.TZDateTime.now(tz.UTC).add(after);
    final android = AndroidNotificationDetails(
      _messagesChannel.id,
      _messagesChannel.name,
      channelDescription: _messagesChannel.description,
      importance: Importance.high,
      priority: Priority.high,
    );
    try {
      await _plugin.zonedSchedule(
        specialLeftId,
        title,
        body,
        when,
        NotificationDetails(android: android, iOS: const DarwinNotificationDetails()),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: jsonEncode({'type': 'special_left'}),
      );
    } catch (_) {
      // Un rappel de confort : jamais une erreur a montrer.
    }
  }

  /// Annule le rappel « dernier message special » (plus aucun, ou deja fait).
  static Future<void> cancelSpecialLeftReminder() async {
    if (kIsWeb) return;
    await ensureReady();
    await _plugin.cancel(specialLeftId);
  }

  /// Drop the pending onboarding reminder (called once onboarding completes,
  /// or when the user comes back to the app before it fires).
  static Future<void> cancelOnboardingReminder() async {
    if (kIsWeb) return;
    await ensureReady();
    await _plugin.cancel(onboardingReminderId);
  }

  /// Standard heads-up banner for a non-call event (chat / friend / like).
  static Future<void> showMessage({
    required int id,
    required String title,
    String? body,
    String? imageUrl,
    Map<String, dynamic>? data,
  }) async {
    if (kIsWeb) return;
    await ensureReady();
    final avatar = await _androidAvatar(imageUrl);
    final android = AndroidNotificationDetails(
      _messagesChannel.id,
      _messagesChannel.name,
      channelDescription: _messagesChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      largeIcon: avatar,
    );
    const darwin = DarwinNotificationDetails();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: darwin),
      payload: data == null ? null : jsonEncode(data),
    );
  }
}
