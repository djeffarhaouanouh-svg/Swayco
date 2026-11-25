import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_settings.dart';
import 'supabase_service.dart';

/// Ce qu'une personne en ligne est en train de faire (la bulle de la page
/// Messages, handoff « messages_bulles »). Priorité : appel > écrit.
enum PeerActivity { call, typing }

/// Le signal d'activité GLOBAL : un seul canal Realtime (`activity-v2`), où chaque
/// client qui fait quelque chose annonce `{user, call, typing}` et le
/// répète toutes les [_heartbeat] tant que ça dure. Rien en base, rien de stocké.
///
/// • Qui publie : l'écran d'appel ([setCall]) et le champ de saisie d'un fil
///   ([setTyping]).
/// • Qui écoute : la page Messages, seulement quand elle est sous les yeux
///   ([setWatching]).
/// • Une annonce sans nouvelles pendant [_expiry] s'éteint toute seule.
/// • Confidentialité : qui masque son statut (`hideOnlineLocal`) ne publie rien et
///   ne voit rien (réciprocité, comme `isPeerOnline`).
/// • « Écrit » est visible de tous mes amis, peu importe à qui l'on écrit.
abstract final class ActivitySignal {
  static const _heartbeat = Duration(seconds: 3);
  static const _expiry = Duration(seconds: 8);

  /// Change à chaque évolution de ce que font les autres : la page se redessine.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static RealtimeChannel? _channel;
  static bool _watching = false;
  static bool _foreground = true;
  static _Lifecycle? _lifecycle;
  static Timer? _beat;
  static Timer? _sweep;

  // Mon état.
  static bool _call = false;
  static bool _typing = false;

  // L'état des autres : user → annonce.
  static final Map<String, _Entry> _peers = {};

  static String get _myId =>
      isSupabaseReady ? (Supabase.instance.client.auth.currentUser?.id ?? '') : '';

  // ── Publier ────────────────────────────────────────────────────────────────

  /// Un compteur et non un simple booléen : quand un écran d'appel en remplace un
  /// autre (sonnerie → appel), le nouveau s'ouvre AVANT que l'ancien ne se ferme ;
  /// avec un booléen, la fermeture de l'ancien éteignait « en appel » pour toute
  /// la durée de l'appel.
  static int _callScreens = 0;

  static void setCall(bool on) {
    _callScreens = on ? _callScreens + 1 : (_callScreens > 0 ? _callScreens - 1 : 0);
    final now = _callScreens > 0;
    if (_call == now) return;
    _call = now;
    _changed();
  }

  /// Seulement « j'écris » (oui / non) : À QUI l'on écrit ne quitte jamais le
  /// téléphone — le canal est commun à tous les utilisateurs.
  static void setTyping(bool on) {
    if (_typing == on) return;
    _typing = on;
    _changed();
  }

  /// Ce que je publie vraiment : un APPEL continue même app en arrière-plan
  /// (écran verrouillé, autre app au premier plan) ; « écrit » seulement quand
  /// l'app est au premier plan.
  static bool get _hasState => _call || (_foreground && _typing);

  static bool get _mayPublish =>
      !AppSettings.hideOnlineLocal.value && _myId.isNotEmpty;

  /// Ai-je annoncé « je fais quelque chose » sans l'avoir encore éteint ?
  static bool _announced = false;

  static void _changed() {
    _lifecycle ??= _Lifecycle()..attach();
    _beat?.cancel();
    _beat = null;
    if (_hasState && _mayPublish) {
      _send();
      _beat = Timer.periodic(_heartbeat, (_) => _send());
    } else if (_announced) {
      // Dernier mot : « je ne fais plus rien », pour que la bulle s'éteigne tout
      // de suite chez les autres.
      _send(force: true);
    }
  }

  /// L'annonce passe par le SERVEUR (`publish_activity`, migration 0097) : c'est
  /// lui qui y met mon identifiant, d'après ma session. Personne ne peut donc
  /// annoncer à la place d'un autre (les clients n'ont pas le droit d'écrire sur
  /// le canal, seulement de l'écouter).
  static void _send({bool force = false}) {
    if (_myId.isEmpty) return;
    final idle = !(_hasState && _mayPublish);
    if (idle && !force) return;
    _announced = !idle;
    unawaited(_publish(idle));
  }

  static Future<void> _publish(bool idle) async {
    try {
      await Supabase.instance.client.rpc('publish_activity', params: {
        'p_call': !idle && _call,
        'p_typing': !idle && _foreground && _typing,
      });
    } catch (e) {
      debugPrint('ActivitySignal publish failed: $e');
    }
  }

  // ── Écouter ────────────────────────────────────────────────────────────────

  /// La page Messages est sous les yeux (ou non).
  static void setWatching(bool on) {
    if (_watching == on) return;
    _watching = on;
    _lifecycle ??= _Lifecycle()..attach();
    if (on) {
      _ensureChannel();
      _sweep ??= Timer.periodic(const Duration(seconds: 1), (_) => _expire());
    } else {
      _sweep?.cancel();
      _sweep = null;
      if (_peers.isNotEmpty) {
        _peers.clear();
        revision.value++;
      }
      _releaseChannel();
    }
  }

  /// Ce que fait [peerId] — ou null. [meId] n'est plus utilisé pour « écrit » :
  /// on voit qu'une personne écrit, peu importe à qui.
  static PeerActivity? of(String peerId, String meId) {
    if (AppSettings.hideOnlineLocal.value) return null;
    final e = _peers[peerId];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > _expiry) return null;
    if (e.call) return PeerActivity.call;
    // « Écrit » se voit peu importe à qui la personne écrit.
    if (e.typing) return PeerActivity.typing;
    return null;
  }

  static void _onBroadcast(Map<String, dynamic> message) {
    if (!_watching || AppSettings.hideOnlineLocal.value) return;
    final inner = message['payload'];
    final data = inner is Map ? inner : message;
    final user = data['user']?.toString() ?? '';
    if (user.isEmpty || user == _myId) return;
    final e = _Entry(
      call: data['call'] == true,
      typing: data['typing'] == true,
      at: DateTime.now(),
    );
    final old = _peers[user];
    if (!e.call && !e.typing) {
      if (_peers.remove(user) != null) revision.value++;
      return;
    }
    _peers[user] = e;
    if (old == null ||
        old.call != e.call ||
        old.typing != e.typing) {
      revision.value++;
    }
  }

  static void _expire() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere((_, e) => now.difference(e.at) > _expiry);
    if (_peers.length != before) revision.value++;
  }

  // ── Canal ──────────────────────────────────────────────────────────────────

  /// Le canal PRIVÉ d'écoute : seuls les comptes connectés le reçoivent, et seul
  /// le serveur y écrit.
  static void _ensureChannel() {
    if (_channel != null || !isSupabaseReady) return;
    _channel = Supabase.instance.client
        .channel(
          'activity-v2',
          opts: const RealtimeChannelConfig(private: true),
        )
        .onBroadcast(event: 'act', callback: _onBroadcast);
    _channel!.subscribe((status, error) {
      if (error != null) debugPrint('ActivitySignal channel: $status $error');
    });
  }

  static void _releaseChannel() {
    final c = _channel;
    _channel = null;
    if (c != null) unawaited(Supabase.instance.client.removeChannel(c));
  }
  static void _onLifecycle(AppLifecycleState s) {
    final fg = s == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    // En arrière-plan : Discover et « écrit » se taisent, l'appel continue.
    _changed();
  }
}

class _Entry {
  const _Entry({
    required this.call,
    required this.typing,
    required this.at,
  });

  final bool call;
  final bool typing;
  final DateTime at;
}

class _Lifecycle with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      ActivitySignal._onLifecycle(state);
}
