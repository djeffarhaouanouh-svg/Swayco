import 'dart:async';

import 'package:flutter/foundation.dart';

/// Web-only periodic refresh helper.
///
/// On native (mobile / desktop) we rely on Supabase Realtime websockets,
/// which are well-supported and cheap. On the web build the websocket
/// connection is less reliable (browser throttling, CORS, network
/// hiccups), so callers also want a periodic "just refetch" tick to stay
/// fresh without forcing the user to pull-to-refresh.
///
/// `every(...)` returns `null` on non-web — callers store the result and
/// `?.cancel()` it on dispose unconditionally, which makes the call sites
/// trivially short and platform-agnostic.
abstract final class WebPoll {
  static Timer? every(Duration interval, FutureOr<void> Function() tick) {
    if (!kIsWeb) return null;
    return Timer.periodic(interval, (_) => tick());
  }
}

/// Un battement périodique qui tourne sur TOUTES les plateformes.
///
/// [WebPoll] existe parce que le natif s'appuie sur les websockets Realtime.
/// Mais certaines données n'ont AUCUN canal Realtime — la présence
/// (`profiles.last_seen`) n'est écoutée nulle part —, et sans un rafraîchi
/// périodique elles restent figées à la valeur du dernier chargement : sur
/// mobile, personne ne passait jamais «en ligne» tant qu'on ne tirait pas la
/// liste vers le bas.
abstract final class AppPoll {
  static Timer every(Duration interval, FutureOr<void> Function() tick) =>
      Timer.periodic(interval, (_) => tick());
}
