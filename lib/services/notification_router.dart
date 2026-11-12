import 'package:flutter/foundation.dart';

import 'analytics.dart';

/// One tapped-notification routing intent — the FCM `type`
/// (e.g. 'live_call', 'message', 'incoming_call') plus its data payload.
class NotificationIntent {
  const NotificationIntent({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;
}

/// Bridges "the user tapped a push notification" to in-app navigation.
///
/// The platform notification client (FCM on native) calls [submit] when
/// a notification is tapped — both for a background tap and for a cold
/// launch from terminated. [RootShell] listens to [pending], routes to
/// the matching screen, then calls [consume].
///
/// Deliberately Firebase-free so it compiles on every target; on web
/// (no push) it simply never fires.
abstract final class NotificationRouter {
  /// The most recent tapped notification awaiting handling, or null.
  static final ValueNotifier<NotificationIntent?> pending =
      ValueNotifier<NotificationIntent?>(null);

  /// Feed a tapped notification's data payload. Ignored when it carries
  /// no `type` (nothing to route on).
  static void submit(Map<String, dynamic>? data) {
    if (data == null) return;
    final type = data['type']?.toString().trim() ?? '';
    if (type.isEmpty) return;
    // « L'app a été ouverte depuis une notification » : seulement son TYPE
    // (message, demande d'ami…), jamais le contenu ni la personne. Sert à savoir
    // ce qui fait revenir les gens.
    try {
      Analytics.track('notification_open', props: {'type': type});
    } catch (_) {}
    pending.value = NotificationIntent(type: type, data: data);
  }

  /// Called by the consumer once the intent has been handled.
  static void consume() => pending.value = null;
}
