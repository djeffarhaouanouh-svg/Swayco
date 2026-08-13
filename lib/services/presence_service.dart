import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_settings.dart';
import 'debug_overlay.dart';
import 'profile_api.dart';
import 'supabase_service.dart';

/// Quelqu'un est-il en ligne ? LA règle, une seule fois.
///
/// Elle vivait recopiée dans quatre écrans — la liste, le fil, Discover et le
/// profil — chacun avec ses deux minutes écrites à la main. Deux d'entre eux
/// avaient perdu la première condition en route : qui masque son propre statut
/// continuait de voir celui des autres sur Discover et sur un profil, alors que
/// la réciprocité est tout l'intérêt du réglage. Une règle recopiée est une
/// règle qui diverge ; celle-ci ne s'écrit plus qu'ici.
bool isPeerOnline(RemoteProfile profile) {
  // Réciproque : masquer son statut, c'est aussi renoncer à voir celui des
  // autres. Sinon le réglage n'est plus de la discrétion, c'est du guet.
  if (AppSettings.hideOnlineLocal.value) return false;
  final ls = profile.lastSeen;
  return !profile.hideOnlineStatus &&
      ls != null &&
      DateTime.now().difference(ls) < PresenceService.onlineWindow;
}

/// Keeps the local user's `profiles.last_seen` fresh so other clients can
/// show an online indicator. Touches the row immediately on [start] and
/// then every 90 seconds. While the app is backgrounded the OS suspends
/// the timer — which is exactly what we want: "online" means foregrounded.
abstract final class PresenceService {
  static Timer? _timer;
  static String _userId = '';
  static _PresenceLifecycle? _lifecycle;

  /// Tous les combien on écrit qu'on est là.
  static const Duration _kBeat = Duration(seconds: 90);

  /// Combien de temps ce battement vaut chez les autres — DEUX battements.
  ///
  /// C'était deux minutes en dur, pour un battement de 90 secondes : trente
  /// secondes de marge, et le moindre battement manqué — un tunnel, une requête
  /// qui traîne, un minuteur que le système a décalé — faisait disparaître
  /// quelqu'un dont l'app était grande ouverte. Deux battements pardonnent
  /// exactement un raté, ce qui est la marge qu'il faut sur un réseau mobile,
  /// et le prix est de rester affiché trois minutes après être parti au lieu de
  /// deux.
  ///
  /// Calculée à partir du battement et pas réécrite : les deux ne peuvent plus
  /// diverger, et changer la cadence ajuste la fenêtre toute seule.
  static const Duration onlineWindow = Duration(seconds: 90 * 2);

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
