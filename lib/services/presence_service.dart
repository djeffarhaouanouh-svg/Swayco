import 'dart:async';

import 'package:flutter/widgets.dart';

import 'debug_overlay.dart';
import 'profile_api.dart';
import 'supabase_service.dart';

/// Keeps the local user's `profiles.last_seen` fresh so other clients can
/// show an online indicator. Touches the row immediately on [start] and
/// then every 90 seconds. While the app is backgrounded the OS suspends
/// the timer — which is exactly what we want: "online" means foregrounded.
abstract final class PresenceService {
  static Timer? _timer;
  static String _userId = '';
  static _PresenceLifecycle? _lifecycle;

  /// Combien de temps un battement vaut chez les autres.
  ///
  /// Le lecteur considère quelqu'un en ligne si son `last_seen` a moins de deux
  /// minutes (`isPeerOnline`), et on bat toutes les 90 s : il reste donc une
  /// marge de 30 s pour un battement perdu. Les deux valeurs vont ensemble —
  /// allonger celle-ci sans allonger l'autre fait clignoter tout le monde.
  static const Duration _kBeat = Duration(seconds: 90);

  /// Begin (or re-target) the heartbeat for [userId]. Idempotent — calling
  /// it again with the same id while already running is a no-op.
  static void start(String userId) {
    if (userId.isEmpty || !isSupabaseReady) return;
    if (userId == _userId && _timer != null) return;
    _userId = userId;
    _timer?.cancel();
    // Sur téléphone, l'app passe en arrière-plan sans arrêt, et le système gèle
    // le minuteur avec elle. Au retour, le dernier battement peut dater de 89
    // secondes : deux minutes plus tard on est déclaré hors ligne alors qu'on
    // regarde l'écran, et il faut attendre le tick suivant pour reparaître.
    // D'où un battement à chaque reprise — c'est le moment où être vu compte le
    // plus, puisque c'est là qu'on ouvre l'app pour parler à quelqu'un.
    //
    // Rien à faire sur le web, où l'onglet reste au premier plan ; l'observateur
    // ne coûte rien et évite un cas de plus à distinguer.
    if (_lifecycle == null) {
      _lifecycle = _PresenceLifecycle();
      WidgetsBinding.instance.addObserver(_lifecycle!);
    }
    DebugOverlay.log('presence: heartbeat started');
    _touch();
    _timer = Timer.periodic(_kBeat, (_) => _touch());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _userId = '';
    final l = _lifecycle;
    if (l != null) {
      WidgetsBinding.instance.removeObserver(l);
      _lifecycle = null;
    }
  }

  /// Reparaître tout de suite, sans attendre le prochain battement.
  static void touchNow() => _touch();

  static void _touch() {
    if (_userId.isEmpty) return;
    unawaited(ProfileApi.touchLastSeen(_userId));
  }
}

class _PresenceLifecycle extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) PresenceService.touchNow();
  }
}
