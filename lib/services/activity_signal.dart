import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_settings.dart';
import 'supabase_service.dart';

/// Ce qu'une personne en ligne est en train de faire (la bulle de la page
/// Messages, handoff « messages_bulles »). Priorité : appel > écrit.
enum PeerActivity { call, typing }

/// Le signal d'activité GLOBAL : un seul canal Realtime (`activity`), où chaque
/// client qui fait quelque chose annonce `{user, call, typingTo}` et le
/// répète toutes les [_heartbeat] tant que ça dure. Rien en base, rien de stocké.
///
/// • Qui publie : l'écran d'appel ([setCall]) et le champ de saisie d'un fil
///   ([setTypingTo]).
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
  static bool _subscribed = false;
  static bool _watching = false;
  static bool _foreground = true;
  static _Lifecycle? _lifecycle;
  static Timer? _beat;
  static Timer? _sweep;

  // Mon état.
  static bool _call = false;
  static String _typingTo = '';

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

  /// [peerId] vide = je n'écris plus.
  static void setTypingTo(String peerId) {
    if (_typingTo == peerId) return;
    _typingTo = peerId;
    _changed();
  }

  /// Ce que je publie vraiment : un APPEL continue même app en arrière-plan
  /// (écran verrouillé, autre app au premier plan) ; « écrit » seulement quand
  /// l'app est au premier plan.
  static bool get _hasState => _call || (_foreground && _typingTo.isNotEmpty);

  static bool get _mayPublish =>
      !AppSettings.hideOnlineLocal.value && _myId.isNotEmpty;

  static void _changed() {
    _lifecycle ??= _Lifecycle()..attach();
    _ensureChannel();
    _beat?.cancel();
    _beat = null;
    if (_hasState && _mayPublish) {
      _send();
      _beat = Timer.periodic(_heartbeat, (_) => _send());
    } else {
      // Dernier mot : « je ne fais plus rien », pour que la bulle s'éteigne tout
      // de suite chez les autres.
      _send(force: true);
    }
    _releaseIfIdle();
  }

  static void _send({bool force = false}) {
    final ch = _channel;
    if (ch == null || !_subscribed) return;
    if (!force && !(_hasState && _mayPublish)) return;
    final idle = !(_hasState && _mayPublish);
    unawaited(
      ch
          .sendBroadcastMessage(event: 'act', payload: {
            'user': _myId,
            'call': idle ? false : _call,
            'typingTo': idle ? '' : (_foreground ? _typingTo : ''),
          })
          .catchError((Object e) {
            debugPrint('ActivitySignal send failed: $e');
            return ChannelResponse.error;
          }),
    );
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
      _releaseIfIdle();
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
    if (e.typingTo.isNotEmpty) return PeerActivity.typing;
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
      typingTo: data['typingTo']?.toString() ?? '',
      at: DateTime.now(),
    );
    final old = _peers[user];
    if (!e.call && e.typingTo.isEmpty) {
      if (_peers.remove(user) != null) revision.value++;
      return;
    }
    _peers[user] = e;
    if (old == null ||
        old.call != e.call ||
        old.typingTo != e.typingTo) {
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

  static void _ensureChannel() {
    if (_channel != null || !isSupabaseReady) return;
    _channel = Supabase.instance.client
        .channel('activity')
        .onBroadcast(event: 'act', callback: _onBroadcast);
    _channel!.subscribe((status, error) {
      _subscribed = status == RealtimeSubscribeStatus.subscribed;
      if (_subscribed && _hasState && _mayPublish) _send();
    });
  }

  static void _releaseIfIdle() {
    if (_watching || _hasState) return;
    final ch = _channel;
    if (ch == null) return;
    // Laisse partir le « je ne fais plus rien » avant de quitter le canal.
    Timer(const Duration(milliseconds: 600), () {
      if (_watching || _hasState) return;
      final c = _channel;
      _channel = null;
      _subscribed = false;
      if (c != null) {
        unawaited(Supabase.instance.client.removeChannel(c));
      }
    });
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
    required this.typingTo,
    required this.at,
  });

  final bool call;
  final String typingTo;
  final DateTime at;
}

class _Lifecycle with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      ActivitySignal._onLifecycle(state);
}
