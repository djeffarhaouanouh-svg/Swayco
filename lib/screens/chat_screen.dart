import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeChannel, Supabase;

import '../services/analytics.dart';
import '../services/app_settings.dart';
import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/chat_api.dart';
import '../services/chat_unread.dart';
import '../services/debug_overlay.dart';
import '../services/device_id.dart';
import '../services/last_interaction.dart';
import '../services/match_seen.dart';
import '../services/muted_calls.dart';
import '../services/friendship_api.dart';
import '../services/nav_tab.dart';
import '../services/notif_enable_flow.dart';
import '../services/notification_client.dart';
import '../services/profile_api.dart';
import '../services/presence_service.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/wave_api.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import '../widgets/appear.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
import '../widgets/swayco_wave_promo.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

/// Combien de temps un match reste dans le rail "Nouveaux matchs". Le compte
/// part du match, pas du premier message : la bulle et la ligne coexistent
/// pendant toute cette fenêtre.
const Duration _kMatchBubbleLife = Duration(days: 7);

/// La police des chiffres et des titres de section : une chasse fixe, pour que
/// les heures d'une ligne à l'autre tombent sur la même colonne et que les
/// libellés se lisent comme des étiquettes, pas comme du texte.
const String _kMono = 'monospace';

/// Le fil de cheveu qui sépare les sections — presque rien, juste de quoi dire
/// que ce qui suit est autre chose.
const Color _kHairline = Color(0x12FFFFFF);

/// WhatsApp-style chat home: lists every accepted friend (union of followers
/// + following). Tapping a row opens the direct-message thread; the trailing
/// video icon launches a call directly with that friend.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.translation = const NoOpRealtimeTranslation(),
  });

  final RealtimeTranslationPort translation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  String _myId = '';
  List<RemoteProfile> _friends = const [];
  /// Peer ids with an accepted friendship — drives "Supprimer le match".
  Set<String> _matchedIds = const {};
  /// Matchs des 7 derniers jours, du plus récent au plus ancien — le rail de
  /// bulles sous le logo. Ils ont AUSSI leur ligne dans Messages ; la bulle
  /// disparaît quand la fenêtre expire, pas quand la conversation démarre.
  List<RemoteProfile> _newMatches = const [];
  /// Matches the user has already laid eyes on — they stay in the rail but
  /// stop counting toward the badge.
  Set<String> _seenMatches = const {};
  /// Fires a few seconds after the rail is on screen: by then the user has
  /// seen the new matches, so the badge clears.
  Timer? _matchSeenTimer;
  Map<String, ChatMessage> _latestByConv = const {};
  // Raw inbound messages (not yet known-seen at _reload() time) — the read
  // pointer itself is NOT cached here. [_isUnread]/[_unreadCountFor] read
  // it live from [ChatUnread.threadSeenAt] (never the global floor — that
  // would clear a row just for landing on this tab) so a thread opened
  // from ANY path (this list, a push notification, …) clears its row
  // immediately, without needing that path to remember to trigger a reload.
  List<({String conversationId, DateTime createdAt})> _inbound = const [];
  bool _loading = true;
  String? _error;
  /// Bumps on every [_reload] so an older in-flight fetch cannot overwrite
  /// a newer one and yank a row (Alice flashing in, then out).
  int _reloadSeq = 0;
  Timer? _pollTimer;

  /// Le rafraîchi de PRÉSENCE, lui, tourne aussi sur mobile : `last_seen` n'a
  /// pas de canal Realtime, donc sans ce battement la pastille verte reste
  /// celle du chargement initial — quelqu'un qui se connecte après coup
  /// n'apparaissait jamais en ligne.
  Timer? _presenceTimer;
  RealtimeChannel? _friendshipChannel;
  /// True when OS notifications are off (never asked or refused). Drives the
  /// recovery banner at the top of the conversation list — the moment where a
  /// missed-message notification matters most. Dismissible per session.
  bool _notifBlocked = false;
  bool _notifBannerDismissed = false;

  /// Ce qu'il me reste de signes 👋 vers chaque personne, tel que le serveur
  /// le compte. Une personne absente de la carte n'a rien reçu ces 24 h :
  /// tout lui est ouvert. Rechargé à chaque [_reload] pour que les boutons
  /// déjà à sec partent grisés au lieu de se découvrir sous le doigt.
  Map<String, WaveQuota> _waveQuota = const {};

  /// Les signes qu'on m'a faits et que je n'ai pas encore vus, par personne.
  /// La ligne les affiche à la place du dernier message.
  Map<String, DateTime> _wavesToMe = const {};

  /// Envoi en cours — le bouton de CETTE ligne tourne au lieu de réagir deux
  /// fois à un doigt nerveux.
  final Set<String> _waving = <String>{};

  /// One-shot "faire signe" coach, montré une seule fois au-dessus de la nav,
  /// dès qu'il y a au moins une conversation à prévisualiser.
  bool _showWavePromo = false;

  Future<void> _maybeShowWavePromo() async {
    if (await UserPrefs.isWavePromoSeen()) return;
    await UserPrefs.markWavePromoSeen();
    if (!mounted) return;
    setState(() => _showWavePromo = true);
  }

  Future<void> _checkNotifStatus() async {
    final blocked = (await NotificationClient.notifStatus()) != 'enabled';
    if (!mounted || blocked == _notifBlocked) return;
    setState(() => _notifBlocked = blocked);
  }

  Future<void> _onEnableNotifs() async {
    await NotifEnableFlow.run(context);
    await _checkNotifStatus();
  }

  @override
  void initState() {
    super.initState();
    Analytics.track('screen_view', props: {'screen': 'chat'});
    WidgetsBinding.instance.addObserver(this);
    // Rebuild when the local "hide my online status" toggle flips
    // so the green dots on every row vanish (or come back)
    // immediately, without waiting for the 7 s poll.
    AppSettings.hideOnlineLocal.addListener(_onHideOnlineChanged);
    NavTab.index.addListener(_onNavTabChanged);
    // A thread can be marked read from OUTSIDE this list's own _openThread
    // (a push-notification tap pushes ChatThreadScreen straight from
    // RootShell) — repaint the rows whenever ChatUnread's read pointer
    // moves, instead of relying on every possible entry point remembering
    // to trigger a reload on its way back.
    ChatUnread.revision.addListener(_onUnreadRevisionChanged);
    _reload();
    _watchFriendships();
    _checkNotifStatus();
    // Web build doesn't always get realtime push reliably — poll the list
    // silently so new messages / new friends appear without pull-to-refresh.
    _pollTimer = WebPoll.every(
      const Duration(seconds: 7),
      () => _reload(silent: true),
    );
    // Sur le web, le rechargement complet ci-dessus s'en charge déjà.
    if (!kIsWeb) {
      _presenceTimer = AppPoll.every(
        const Duration(seconds: 30),
        _refreshPresence,
      );
    }
    // NOTE: we deliberately do NOT call ChatUnread.markAllSeen() here.
    // Visiting the list is not reading a thread — the nav badge must keep
    // showing the same unread total as the row pastilles.
  }

  /// A new match must land in this list right away, not on the next resume.
  Future<void> _watchFriendships() async {
    if (!isSupabaseReady) return;
    final id = await DeviceId.getOrCreate();
    if (!mounted || id.isEmpty) return;
    _friendshipChannel = FriendshipApi.subscribeMine(
      userId: id,
      onChange: () => _reload(silent: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.hideOnlineLocal.removeListener(_onHideOnlineChanged);
    NavTab.index.removeListener(_onNavTabChanged);
    ChatUnread.revision.removeListener(_onUnreadRevisionChanged);
    _matchSeenTimer?.cancel();
    _pollTimer?.cancel();
    _presenceTimer?.cancel();
    final ch = _friendshipChannel;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    super.dispose();
  }

  void _onHideOnlineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onUnreadRevisionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onNavTabChanged() {
    if (!mounted) return;
    if (NavTab.index.value == NavTab.chat) {
      // This screen lives in an IndexedStack, so it is built once at launch.
      // Without this, a match made while the user was on Discover only shows
      // up after an app resume (the poll below is web-only).
      _reload(silent: true);
      _scheduleMatchSeen();
    } else {
      _matchSeenTimer?.cancel();
      _matchSeenTimer = null;
    }
  }

  /// The badge is a "you have new matches" nudge, so it dies once the rail has
  /// actually been looked at: three seconds on the Messages tab with unseen
  /// bubbles on screen is enough. The bubbles themselves stay.
  void _scheduleMatchSeen() {
    if (_matchSeenTimer != null) return;
    if (_unseenMatches == 0) return;
    if (NavTab.index.value != NavTab.chat) return;
    _matchSeenTimer = Timer(const Duration(seconds: 3), () async {
      _matchSeenTimer = null;
      if (!mounted) return;
      final ids = _newMatches.map((p) => p.id).toList();
      final seen = await MatchSeen.markSeen(
        ids,
        stillMatched: ids.toSet(),
      );
      if (!mounted) return;
      setState(() => _seenMatches = seen);
    });
  }

  /// Matches in the rail the user hasn't laid eyes on yet — the badge count.
  int get _unseenMatches =>
      _newMatches.where((p) => !_seenMatches.contains(p.id)).length;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
      // Re-check after the user may have toggled notifications in Settings.
      _checkNotifStatus();
    }
  }

  Future<void> _reload({bool silent = false}) async {
    if (!mounted) return;
    final seq = ++_reloadSeq;
    // After the first paint, keep the current rows on screen. Swapping in
    // the skeleton made the 4th conversation (already opened) vanish, then
    // FadeSlideIn replayed it as if it were new.
    if (!silent && _friends.isEmpty && _newMatches.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final id = await DeviceId.getOrCreate();
      if (!isSupabaseReady) {
        if (!mounted || seq != _reloadSeq) return;
        setState(() {
          _myId = id;
          _friends = const [];
          _matchedIds = const {};
          _newMatches = const [];
          _loading = false;
        });
        return;
      }
      // Fire every independent request in parallel — previously each
      // await sat in front of the next, so the list staggered in over
      // 6-7× the latency of one request. Future.wait collapses them
      // into a single round-trip from the user's point of view.
      final results = await Future.wait([
        FriendshipApi.fetchMatchesNewestFirst(id),
        // Latest message per conversation involving me — used for the
        // "WhatsApp-style" last-message preview and the sort order.
        ChatApi.fetchLatestPerConversation(id),
        // Conversations the user deleted from their list (local
        // "delete for me"). A row stays hidden until a message newer
        // than the clear timestamp arrives.
        ChatUnread.clearedConversations(),
        // Either side of a block hides the row in both directions.
        BlockApi.fetchMyBlockedProfiles(id),
        BlockApi.fetchMyBlockerIds(),
        // Recent inbound messages — counted per conversation for the badge.
        ChatApi.fetchInboundForUnread(id),
        // Les appels ne laissent pas de message : sans ce registre, appeler
        // quelqu'un ne remonte pas sa ligne.
        LastInteraction.load(),
      ]);
      final matchRows =
          results[0] as List<({RemoteProfile profile, DateTime? matchedAt})>;
      final matches = [for (final m in matchRows) m.profile];
      final matchedAtById = {
        for (final m in matchRows)
          if (m.matchedAt != null) m.profile.id: m.matchedAt!,
      };
      final latest = results[1] as Map<String, ChatMessage>;
      final cleared = results[2] as Map<String, DateTime>;
      final iBlocked = results[3] as List<RemoteProfile>;
      final blockedMe = results[4] as Set<String>;
      final inbound =
          results[5] as List<({String conversationId, DateTime createdAt})>;
      final touched = results[6] as Map<String, DateTime>;

      final byId = <String, RemoteProfile>{};
      for (final p in matches) {
        byId[p.id] = p;
      }
      // Keep conversations alive after a match ends: the messages outlive the
      // friendship row, so any peer we have a thread with — even a now-
      // stranger — still earns a row here. Pull the profiles matches missed.
      final convPeerIds = <String>{};
      for (final msg in latest.values) {
        final peer = msg.senderId == id ? msg.recipientId : msg.senderId;
        if (peer.isEmpty || peer == id || byId.containsKey(peer)) continue;
        convPeerIds.add(peer);
      }
      if (convPeerIds.isNotEmpty) {
        for (final p in await ProfileApi.fetchByIds(convPeerIds.toList())) {
          byId[p.id] = p;
        }
      }
      final blockedByMe = iBlocked.map((p) => p.id).toSet();
      final hiddenPeers = {...blockedByMe, ...blockedMe};
      byId.removeWhere((k, _) => hiddenPeers.contains(k));

      String convIdFor(String otherId) {
        final ids = [id, otherId]..sort();
        return 'dm-${ids[0]}-${ids[1]}';
      }

      bool isVisible(RemoteProfile p) {
        final clearedAt = cleared[convIdFor(p.id)];
        if (clearedAt == null) return true;
        // A match made AFTER the row was cleared is a fresh relationship
        // (typically unmatch → re-match): the conversation comes back even
        // though nobody has written yet.
        final matchedAt = matchedAtById[p.id];
        if (matchedAt != null && matchedAt.isAfter(clearedAt)) return true;
        // Otherwise it re-surfaces once a newer message lands.
        final lm = latest[convIdFor(p.id)];
        return lm != null && lm.createdAt.isAfter(clearedAt);
      }

      final visible = byId.values.where(isVisible).toSet();
      // A racy second fetch can miss a peer the list already showed (limit
      // window, fetchByIds hiccup). Keep the row the user already saw unless
      // they blocked it or deleted it.
      for (final p in _friends) {
        if (hiddenPeers.contains(p.id)) continue;
        if (visible.any((v) => v.id == p.id)) continue;
        if (isVisible(p)) visible.add(p);
      }
      // Une bulle ET une ligne, pas l'un OU l'autre. La bulle tient
      // [_kMatchBubbleLife] à partir du match (qu'on ait écrit ou non), puis
      // elle s'efface ; la ligne, elle, reste. `matches` arrive déjà du plus
      // récent au plus ancien, donc le dernier match ouvre le rail.
      final now = DateTime.now();
      final newMatches = [
        for (final p in matches)
          if (visible.contains(p))
            if (matchedAtById[p.id] case final t?)
              if (now.difference(t) < _kMatchBubbleLife) p,
      ];
      final seenMatches = await MatchSeen.load();
      // Tout le monde a sa ligne : un match sans message compris. Les rangées
      // muettes descendent sous les conversations, du match le plus récent au
      // plus ancien.
      // La date qui classe une ligne : le dernier message, ou le dernier appel
      // si celui-ci est plus récent. Appeler quelqu'un le fait donc remonter en
      // tête, comme lui écrire.
      DateTime? lastTouch(String peerId) {
        final msg = latest[convIdFor(peerId)]?.createdAt;
        final call = touched[peerId];
        if (msg == null) return call;
        if (call == null) return msg;
        return call.isAfter(msg) ? call : msg;
      }

      final friends = visible.toList()
        ..sort((a, b) {
          final la = lastTouch(a.id);
          final lb = lastTouch(b.id);
          if (la == null && lb == null) {
            final ma = matchedAtById[a.id];
            final mb = matchedAtById[b.id];
            if (ma != null && mb != null) return mb.compareTo(ma);
            if (ma != null) return -1;
            if (mb != null) return 1;
            return a.displayName
                .toLowerCase()
                .compareTo(b.displayName.toLowerCase());
          }
          if (la == null) return 1; // peers without messages sink to the bottom
          if (lb == null) return -1;
          return lb.compareTo(la); // most recent first
        });
      if (!mounted || seq != _reloadSeq) return;
      setState(() {
        _myId = id;
        _friends = friends;
        _matchedIds = {for (final p in matches) p.id};
        _newMatches = newMatches;
        _seenMatches = seenMatches;
        _latestByConv = latest;
        _inbound = inbound;
        _loading = false;
      });
      // Les signes 👋 arrivent APRÈS la liste, exprès : ce sont deux requêtes
      // de plus, et une liste qui attend après elles s'afficherait plus tard
      // pour tout le monde, y compris ceux à qui personne n'a fait signe.
      unawaited(_reloadWaves());
      // Landed on Messages with fresh matches → start the "seen" countdown.
      _scheduleMatchSeen();
      if (friends.isNotEmpty) unawaited(_maybeShowWavePromo());
    } catch (e) {
      if (!mounted || seq != _reloadSeq) return;
      setState(() {
        _error = 'Erreur de chargement : $e';
        _loading = false;
      });
    }
  }

  /// Recharge UNIQUEMENT les profils affichés, pour que leur présence soit à
  /// jour. Bien plus léger que [_reload] (une requête au lieu de sept) et
  /// suffisant : seuls `last_seen` et le drapeau «masquer mon statut» bougent
  /// entre deux ouvertures de la page.
  Future<void> _refreshPresence() async {
    if (!mounted || !isSupabaseReady) return;
    // Cet écran vit dans un IndexedStack : il est construit dès le lancement,
    // même si l'utilisateur est sur Discover. Inutile d'interroger le réseau
    // pour des pastilles que personne ne regarde.
    if (NavTab.index.value != NavTab.chat) return;
    final ids = <String>{
      for (final p in _friends) p.id,
      for (final p in _newMatches) p.id,
    }.toList();
    if (ids.isEmpty) return;
    try {
      final fresh = await ProfileApi.fetchByIds(ids);
      if (!mounted || fresh.isEmpty) return;
      final byId = {for (final p in fresh) p.id: p};
      // Ce que la LECTURE voit réellement, prénom par prénom : l'âge du
      // dernier signe de vie, et le verdict de la règle. C'est la seule chose
      // qui manquait pour trancher — on savait que l'écriture partait (la
      // fonction serveur compte bien les profils frais), sans jamais voir ce
      // qui arrivait de l'autre côté.
      DebugOverlay.log(
        'presence: ${[
          for (final p in fresh)
            '${p.displayName.isEmpty ? p.id.substring(0, 4) : p.displayName}'
                '=${p.lastSeen == null ? "jamais" : "${DateTime.now().difference(p.lastSeen!).inSeconds}s"}'
                '${p.hideOnlineStatus ? "/masqué" : ""}'
                '${isPeerOnline(p) ? "/EN LIGNE" : ""}',
        ].join(' ')}'
        '${AppSettings.hideOnlineLocal.value ? "  [je me masque → tout éteint]" : ""}',
      );
      setState(() {
        _friends = [for (final p in _friends) byId[p.id] ?? p];
        _newMatches = [for (final p in _newMatches) byId[p.id] ?? p];
      });
    } catch (e) {
      // La présence est un confort : un échec réseau ne doit rien casser.
      DebugOverlay.log('presence: lecture échouée $e');
    }
  }

  /// Conversations with at least one unread inbound message — the number in
  /// the "Messages" badge.
  int get _unreadConversations =>
      _friends.where(_isUnread).length;

  String _conversationIdFor(String otherId) {
    final ids = [_myId, otherId]..sort();
    return 'dm-${ids[0]}-${ids[1]}';
  }

  /// Les deux moitiés du 👋 : ce qu'il me reste à donner, et ce qu'on m'a
  /// donné. Silencieux — un plafond qu'on n'a pas pu lire laisse simplement
  /// les boutons actifs, et le serveur tranchera au moment du clic.
  Future<void> _reloadWaves() async {
    if (!isSupabaseReady) return;
    final quota = await WaveApi.quotas();
    final inbound = await WaveApi.unseenInbound();
    if (!mounted) return;
    setState(() {
      _waveQuota = quota;
      _wavesToMe = inbound;
    });
  }

  /// Faire signe à [peer]. Le plafond est compté par le serveur ; ici on ne
  /// fait qu'afficher ce qu'il répond et éteindre le bouton quand il n'y a
  /// plus de signe à donner.
  Future<void> _wave(RemoteProfile peer) async {
    if (_waving.contains(peer.id)) return;
    setState(() => _waving.add(peer.id));
    final me = await ProfileApi.fetchById(_myId);
    final res = await WaveApi.send(
      peerId: peer.id,
      peerLang: peer.language,
      myName: me?.displayName ?? '',
    );
    if (!mounted) return;
    final name = peer.displayName.isNotEmpty
        ? peer.displayName
        : AppStrings.t('call_locked_peer_fallback');
    setState(() {
      _waving.remove(peer.id);
      // Ce que le serveur vient de dire fait autorité sur ce qu'on croyait.
      _waveQuota = {
        ..._waveQuota,
        peer.id: WaveQuota(
          remainingStreak: res.remainingStreak,
          remainingDaily: res.remainingDaily,
        ),
      };
    });
    final key = res.messageKey;
    if (res.ok) {
      _showTopToast(AppStrings.t('wave_sent', args: {'name': name}));
      Analytics.track('wave_sent', props: {'source': 'messages'});
    } else if (key != null) {
      _showTopToast(AppStrings.t(key, args: {'name': name}));
    }
  }

  Future<void> _openThread(RemoteProfile peer) async {
    final convId = _conversationIdFor(peer.id);
    final title = peer.displayName.isNotEmpty
        ? peer.displayName
        : (peer.handle.isNotEmpty ? '@${peer.handle}' : 'Ami');
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatThreadScreen(
          conversationId: convId,
          title: title,
          peerDeviceId: peer.id,
          translation: widget.translation,
        ),
      ),
    );
    // Ouvrir le fil, c'est avoir vu le signe — et ça rouvre du même coup le
    // compteur d'affilée de la personne qui l'a fait.
    if (_wavesToMe.containsKey(peer.id)) {
      unawaited(WaveApi.markSeen(peer.id));
      if (mounted) {
        setState(() => _wavesToMe = {..._wavesToMe}..remove(peer.id));
      }
    }
    _reload(silent: true);
  }

  void _viewProfile(RemoteProfile peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(userId: peer.id),
      ),
    );
  }

  /// Delete a conversation from the chat list — local "delete for me".
  /// The peer's copy is untouched; the row reappears here if they send a
  /// new message later.
  Future<void> _deleteConversation(RemoteProfile peer) async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('delete_conversation'),
      body: AppStrings.t('delete_conversation_body'),
      confirmLabel: AppStrings.t('delete'),
    );
    if (ok != true) return;
    await ChatUnread.markConversationCleared(_conversationIdFor(peer.id));
    await _reload();
  }

  Future<void> _reportPeer(RemoteProfile peer) async {
    if (_myId.isEmpty) return;
    await showReportDialog(
      context,
      reporterId: _myId,
      reportedId: peer.id,
      peerName: peer.displayName.isEmpty
          ? AppStrings.t('incoming_someone')
          : peer.displayName,
    );
  }

  /// Drop the accepted match (not a block) and hide the conversation locally.
  Future<void> _unmatchPeer(RemoteProfile peer) async {
    final name = peer.displayName.isEmpty
        ? AppStrings.t('incoming_someone')
        : peer.displayName;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('unmatch_q', args: {'name': name}),
      body: AppStrings.t('unmatch_body', args: {'name': name}),
      confirmLabel: AppStrings.t('unmatch'),
    );
    if (ok != true || _myId.isEmpty) return;
    try {
      await FriendshipApi.unmatchWith(meId: _myId, peerId: peer.id);
      await ChatUnread.markConversationCleared(_conversationIdFor(peer.id));
      if (!mounted) return;
      _showTopToast('$name · ${AppStrings.t('unmatch')}');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'})),
      ));
    }
  }

  Future<void> _blockPeer(RemoteProfile peer) async {
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('block_peer_q', args: {'name': peer.displayName}),
      body: AppStrings.t('block_peer_body'),
      confirmLabel: AppStrings.t('block'),
    );
    if (ok != true || _myId.isEmpty) return;
    try {
      await BlockApi.block(blockerId: _myId, blockedId: peer.id);
      if (!mounted) return;
      // Cyan top toast as a compact confirmation (reuse the block label).
      _showTopToast('${peer.displayName} · ${AppStrings.t('block')}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.t('error_prefix', args: {'msg': '$e'})),
      ));
    }
  }

  /// Cyan pill notification at the TOP of the screen that auto-dismisses —
  /// used for the block confirmation instead of the default white bottom
  /// snackbar.
  void _showTopToast(String message) {
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopToast(
        message: message,
        onDismissed: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final navBody =
        GlassNavBar.totalReservedHeight + MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      // Classic flat black, matching the conversation thread — no blue mesh.
      backgroundColor: SC.bg,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            // Fixed "Messages" band at the top; the conversation list scrolls
            // underneath it (the band stays pinned, it doesn't scroll away).
            child: Column(
              children: [
                _titleBar,
                // Le liseré qui ferme le header : pleine largeur, bord à bord.
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.10),
                ),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
          if (_showWavePromo)
            Positioned(
              left: 0,
              right: 0,
              bottom: navBody,
              child: SwaycoWavePromo(
                peers: [
                  for (final p in _friends.take(4))
                    WavePromoPeer(
                      avatarUrl: p.avatarUrl,
                      displayName: p.displayName,
                    ),
                ],
                onCta: () => setState(() => _showWavePromo = false),
                onDismiss: () => setState(() => _showWavePromo = false),
              ),
            ),
        ],
      ),
    );
  }

  /// Amis joignables tout de suite — le compteur de la pastille verte.
  int get _onlineFriends => _friends.where(isPeerOnline).length;

  /// The band pinned at the top of the page — the swaycø wordmark on the left,
  /// and on the right the count of friends who are online right now. Le seul
  /// chiffre de la page qui ne parle pas du passé : tout le reste dit ce qui
  /// s'est dit, celui-là dit qui est là.
  Widget get _titleBar => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'swayc'),
                  TextSpan(
                    text: 'ø',
                    style: TextStyle(color: SC.accent),
                  ),
                ],
              ),
              style: TextStyle(
                color: Colors.white,
                fontFamily: SC.brandFont,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            // Personne en ligne = pas de pastille : un « 0 en ligne » est une
            // mauvaise nouvelle affichée en permanence.
            if (_onlineFriends > 0)
              Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: SC.menu,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: SC.online,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppStrings.t(
                        'online_count',
                        args: {'n': '$_onlineFriends'},
                      ),
                      style: const TextStyle(
                        fontFamily: _kMono,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: SC.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _buildBody() {
    if (_loading) {
      // Skeleton list while data lands — keeps the layout in place
      // instead of swapping a centred spinner for a populated list
      // (the old behaviour made rows pop in one by one as each
      // request resolved).
      return const _ChatListSkeleton();
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error!,
          style: const TextStyle(
            color: Color(0xFFFFAB91),
            height: 1.35,
            fontSize: 13,
          ),
        ),
      );
    }
    if (_friends.isEmpty && _newMatches.isEmpty) {
      return const _NoFriendsEmpty();
    }
    // LAYER STRUCTURE: the mesh fond (built in build()) sits at the back; the
    // panel is the middle layer. It lives INSIDE the page scroll view so the
    // WHOLE panel moves when you scroll. A min-height = the available zone
    // makes it fill and rest flush on the nav at rest, so the nav's concave
    // notches hug its rounded bottom corners (Discover-style); once the rows
    // overflow that height the panel grows and the whole thing scrolls.
    final navBody =
        GlassNavBar.totalReservedHeight + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fill = constraints.maxHeight - 12 - navBody;
        return RefreshIndicator(
          color: SC.accent,
          backgroundColor: SC.menu,
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: 12, bottom: navBody),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: fill > 0 ? fill : 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_notifBlocked && !_notifBannerDismissed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          child: _NotifBanner(
                            onEnable: _onEnableNotifs,
                            onDismiss: () =>
                                setState(() => _notifBannerDismissed = true),
                          ),
                        ),
                      // "Nouveaux matchs" — the bubble rail, newest first.
                      if (_newMatches.isNotEmpty) ...[
                        _SectionHeader(
                          label: AppStrings.t('new_matches_section'),
                          count: _unseenMatches,
                          countLeads: true,
                        ),
                        _MatchBubbleRail(
                          matches: _newMatches,
                          seen: _seenMatches,
                          onTap: _openThread,
                        ),
                        // Le trait qui referme le rail : sans lui les bulles et
                        // la première conversation se touchent.
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          child: Divider(
                            height: 37,
                            thickness: 1,
                            color: _kHairline,
                          ),
                        ),
                      ],
                      if (_friends.isNotEmpty)
                        _SectionHeader(
                          label: AppStrings.t('messages_section'),
                          count: _unreadConversations,
                        ),
                      // Conversation rows.
                      for (final (i, p) in _friends.indexed)
                        FadeSlideIn(
                          key: ValueKey(p.id),
                          delay: Duration(milliseconds: i * 55),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FriendChatRow(
                                profile: p,
                                lastMessage:
                                    _latestByConv[_conversationIdFor(p.id)],
                                isMine: _latestByConv[_conversationIdFor(p.id)]
                                        ?.senderId ==
                                    _myId,
                                unread: _isUnread(p),
                                unreadCount: _unreadCountFor(p),
                                onTap: () => _openThread(p),
                                onViewProfile: () => _viewProfile(p),
                                isMatched: _matchedIds.contains(p.id),
                                onUnmatch: () => _unmatchPeer(p),
                                onBlock: () => _blockPeer(p),
                                onReport: () => _reportPeer(p),
                                onDeleteConversation: () =>
                                    _deleteConversation(p),
                                onWave: () => _wave(p),
                                // Rien de connu sur cette personne = rien
                                // d'envoyé ces 24 h : le bouton est ouvert.
                                canWave: _waveQuota[p.id]?.canWave ?? true,
                                waving: _waving.contains(p.id),
                                wavedMeAt: _wavesToMe[p.id],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// True when the peer's last message is newer than the last time I
  /// opened the thread (or I've never opened it). Drives the cyan dot.
  /// La ligne bleue ne suit QUE le point de lecture du fil — jamais le
  /// plancher global.
  ///
  /// Les deux marques ne répondent pas à la même question. Le « 1 » de la
  /// barre de nav dit « il y a du nouveau quelque part » : venir sur Messages
  /// y répond, il s'éteint. La ligne bleue dit « c'est CETTE conversation » :
  /// venir sur Messages n'y répond pas, il faut ouvrir le fil. Les avoir
  /// alignées sur le plancher éteignait la ligne dès l'arrivée sur la liste,
  /// et on ne savait plus où était le message.
  bool _isUnread(RemoteProfile p) {
    final convId = _conversationIdFor(p.id);
    final last = _latestByConv[convId];
    final seen = ChatUnread.threadSeenAt(convId);
    return last != null &&
        last.senderId != _myId &&
        (seen == null || last.createdAt.isAfter(seen));
  }

  /// Number of unread inbound messages in [p]'s conversation (0 = none).
  /// Computed live against [ChatUnread.threadSeenAt] rather than a snapshot
  /// taken at the last [_reload] — the read pointer can move from outside
  /// this list (a push notification opens the thread directly), and this
  /// must reflect that the moment it happens, not at the next reload.
  int _unreadCountFor(RemoteProfile p) {
    final convId = _conversationIdFor(p.id);
    final seen = ChatUnread.threadSeenAt(convId);
    var n = 0;
    for (final m in _inbound) {
      if (m.conversationId != convId) continue;
      if (seen == null || m.createdAt.isAfter(seen)) n++;
    }
    return n;
  }
}

class _FriendChatRow extends StatelessWidget {
  const _FriendChatRow({
    required this.profile,
    required this.lastMessage,
    required this.isMine,
    required this.unread,
    required this.unreadCount,
    required this.onTap,
    required this.onViewProfile,
    required this.isMatched,
    required this.onUnmatch,
    required this.onBlock,
    required this.onReport,
    required this.onDeleteConversation,
    required this.onWave,
    required this.canWave,
    required this.waving,
    this.wavedMeAt,
  });
  final RemoteProfile profile;
  final ChatMessage? lastMessage;
  final bool isMine;
  /// True when the last message is from the peer and hasn't been read
  /// yet — drives the green dot + bold name styling on the row.
  final bool unread;

  /// Number of unread messages in this conversation (0 = none). Drives the
  /// cyan count badge; falls back to a dot when [unread] but the count
  /// window missed it.
  final int unreadCount;
  final VoidCallback onTap;
  final VoidCallback onViewProfile;
  /// Accepted friendship — show "Supprimer le match" above Block.
  final bool isMatched;
  final VoidCallback onUnmatch;
  final VoidCallback onBlock;
  final VoidCallback onReport;
  /// Removes this conversation from the chat list (local "delete for me").
  final VoidCallback onDeleteConversation;
  /// Fait signe à cette personne (le 👋 en bout de ligne).
  final VoidCallback onWave;

  /// Faux quand le plafond vers elle est atteint — le rond s'éteint.
  final bool canWave;

  /// Envoi en cours vers elle.
  final bool waving;

  /// Quand ELLE m'a fait signe sans que je l'aie encore vu. La ligne le dit
  /// à la place du dernier message : un signe qu'on ne voit pas n'a servi à
  /// rien, et la notification a très bien pu ne jamais arriver.
  final DateTime? wavedMeAt;

  /// True when the peer was active in the last 2 minutes, has not
  /// hidden their own online status, AND the local user has not
  /// opted out of presence (reciprocal rule — if I'm hiding I don't
  /// see anyone else's dot either).
  bool get _peerOnline => isPeerOnline(profile);

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final isSameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isSameDay) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    final wasYesterday =
        dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day;
    if (wasYesterday) return 'hier';
    final daysAgo = now.difference(dt).inDays;
    if (daysAgo < 7) {
      const weekdays = [
        'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche',
      ];
      return weekdays[(dt.weekday - 1).clamp(0, 6)];
    }
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$d/$mo';
  }

  /// Long-press menu: mute / unmatch / block / report / delete conversation.
  void _showRowActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SC.menu,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<Set<String>>(
              valueListenable: MutedCalls.ids,
              builder: (_, muted, _) {
                final isMuted = muted.contains(profile.id);
                return ListTile(
                  leading: Icon(
                    isMuted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    color: SC.textPrimary,
                  ),
                  title: Text(
                    AppStrings.t(
                      isMuted ? 'calls_unmute' : 'calls_mute',
                    ),
                    style: const TextStyle(color: SC.textPrimary),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    MutedCalls.setMuted(profile.id, !isMuted);
                  },
                );
              },
            ),
            if (isMatched)
              ListTile(
                leading: const Icon(
                  Icons.heart_broken_outlined,
                  color: SC.textPrimary,
                ),
                title: Text(
                  AppStrings.t('unmatch'),
                  style: const TextStyle(color: SC.textPrimary),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onUnmatch();
                },
              ),
            ListTile(
              leading: const Icon(Icons.block, color: Color(0xFFE53935)),
              title: Text(
                AppStrings.t('block'),
                style: const TextStyle(color: SC.textPrimary),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onBlock();
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: SC.textPrimary),
              title: Text(
                AppStrings.t('report'),
                style: const TextStyle(color: SC.textPrimary),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onReport();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: SC.textPrimary),
              title: Text(
                AppStrings.t('delete_conversation'),
                style: const TextStyle(color: SC.textPrimary),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onDeleteConversation();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.isNotEmpty
        ? profile.displayName
        : (profile.handle.isNotEmpty
            ? '@${profile.handle}'
            : AppStrings.t('chat_no_name'));

    final subtitleParts = <InlineSpan>[];
    // Point levé + date : ce qui a quitté la colonne de droite se retrouve
    // ici, en bout d'aperçu. À PART du flux tronquable — un message long
    // ne doit jamais manger la date, seulement le texte qui la précède.
    String? dateSuffix;
    if (wavedMeAt != null) {
      // Un signe non vu passe DEVANT le dernier message : c'est le plus
      // récent, et c'est le seul des deux qui attend quelque chose de moi.
      subtitleParts.add(TextSpan(
        text: '👋 ${AppStrings.t('wave_received')}',
        style: const TextStyle(
          color: SC.accent,
          fontWeight: FontWeight.w600,
        ),
      ));
    } else if (lastMessage != null &&
        (lastMessage!.body.isNotEmpty || lastMessage!.isImage)) {
      if (isMine) {
        subtitleParts.add(const TextSpan(
          text: 'Vous : ',
          style: TextStyle(
            color: SC.textMuted,
            fontWeight: FontWeight.w500,
          ),
        ));
      }
      subtitleParts.add(TextSpan(
        text: lastMessage!.isImage
            ? AppStrings.t('push_photo')
            : lastMessage!.body,
      ));
      dateSuffix = ' · ${_formatTime(lastMessage!.createdAt)}';
    } else {
      // Jamais un mot échangé : on le dit, au lieu d'inviter à toucher — la
      // ligne entière est déjà la touche.
      subtitleParts.add(TextSpan(text: AppStrings.t('chat_tap_to_chat')));
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showRowActions(context),
        child: Container(
        // Non lu : un voile cyan qui s'éteint vers la droite. Il remplace le
        // aplat uniforme — la ligne se signale du coin de l'œil, sans devenir
        // un bloc de couleur qui écrase le texte posé dessus.
        decoration: unread
            ? BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    SC.accent.withValues(alpha: 0.10),
                    SC.accent.withValues(alpha: 0),
                  ],
                ),
              )
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            // Avatar — tap goes straight to the peer's profile. The light-
            // green presence dot rides the bottom-right corner when online.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onViewProfile,
              child: Stack(
                children: [
                  ProfileAvatar(
                    displayName: profile.displayName,
                    avatarUrl: profile.avatarUrl,
                    size: 52,
                  ),
                  if (_peerOnline)
                    Positioned(
                      right: 1,
                      bottom: 1,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: SC.online,
                          shape: BoxShape.circle,
                          border: Border.all(color: SC.bg, width: 2.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Le prénom seul sur sa ligne : l'heure est partie à droite,
                  // avec le compte, là où l'œil va chercher l'état de la
                  // conversation.
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 16.5,
                      height: 1.2,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                      color: unread ? SC.textPrimary : SC.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // Tronquable : c'est le texte du message qui cède la
                      // place, jamais la date.
                      Flexible(
                        child: RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          text: TextSpan(
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.3,
                              color: unread ? SC.textSecondary : SC.textMuted,
                            ),
                            children: subtitleParts,
                          ),
                        ),
                      ),
                      if (dateSuffix != null)
                        Text(
                          dateSuffix,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.3,
                            color: unread ? SC.textSecondary : SC.textMuted,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // La colonne de droite : l'heure, puis le compte non-lu OU la
            // touche d'appel. Jamais les deux — une conversation qui attend
            // une réponse ne propose pas d'appeler à la place, et une
            // conversation à jour n'a pas de chiffre à montrer.
            //
            // La date/l'heure est partie : le point levé en fin d'aperçu la
            // remplace, et la colonne revient tout entière au 👋.
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (unreadCount > 0)
                  _UnreadBadge(count: unreadCount)
                else if (unread)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: SC.accent,
                      shape: BoxShape.circle,
                    ),
                  )
                else
                  // Fil à jour : la place revient au 👋. C'est le geste de la
                  // page — faire signe sans rien avoir à écrire.
                  _RowWaveButton(
                    onWave: onWave,
                    enabled: canWave,
                    busy: waving,
                  ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

}

/// Filled cyan pill showing the unread-message count on a chat row (caps at
/// 99+). High-contrast — the primary "new messages" signal on the list.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: SC.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: SC.bgDeep,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

/// Snapchat-style recovery banner: when notifications are off, nudge the user
/// to turn them on right where missed messages hurt. Benefit-framed copy, a
/// one-tap "enable" that runs the priming → OS-prompt / Settings flow, and a
/// dismiss for the session.
class _NotifBanner extends StatelessWidget {
  const _NotifBanner({required this.onEnable, required this.onDismiss});

  final VoidCallback onEnable;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: SC.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SC.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_off_rounded,
              color: SC.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppStrings.t('notif_banner_text'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onEnable,
            style: TextButton.styleFrom(
              foregroundColor: SC.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              AppStrings.t('notif_banner_cta'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded,
                color: Colors.white54, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Cyan top-toast that slides down + fades in, holds, then slides up + fades
/// out before removing its own overlay entry via [onDismissed].
class _TopToast extends StatefulWidget {
  const _TopToast({required this.message, required this.onDismissed});

  final String message;
  final VoidCallback onDismissed;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _c.forward();
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    if (!mounted) return;
    await _c.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) => Opacity(
            opacity: _t.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - _t.value) * -14),
              child: child,
            ),
          ),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: SC.accent,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF04141A),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le 👋 au bout de chaque ligne : « je suis là, viens si tu veux ».
///
/// Il a remplacé le raccourci d'appel, et ce n'est pas la même promesse. Un
/// appel sonne, interrompt, et se rate — ce bouton-là ne fait qu'un ping :
/// la personne reçoit une notification et vient quand elle veut. C'est le
/// geste de Houseparty, celui qui coûte assez peu pour qu'on ose, et qu'on
/// plafonne (voir `send_wave`, migration 0057) pour qu'il reste un signe et
/// pas du bruit.
///
/// Verre dépoli, pas de cyan plein : le même [BackdropFilter] que le dock
/// d'appel et le bouton « Message » du profil. Le cyan plein posait un point
/// vif sur CHAQUE ligne — vingt conversations, vingt pastilles qui crient. Le
/// verre laisse la ligne au prénom, et c'est le geste, pas le bouton, qui se
/// voit. Quand il n'y a plus de signe à donner, le verre s'assombrit et
/// l'emoji s'efface à demi — un bouton qui disparaît laisse croire à un bug,
/// un bouton éteint se comprend.
class _RowWaveButton extends StatefulWidget {
  const _RowWaveButton({
    required this.onWave,
    required this.enabled,
    required this.busy,
  });

  final VoidCallback onWave;

  /// Faux quand le plafond est atteint vers cette personne.
  final bool enabled;

  /// Envoi en cours : on n'accepte pas un deuxième doigt.
  final bool busy;

  @override
  State<_RowWaveButton> createState() => _RowWaveButtonState();
}

class _RowWaveButtonState extends State<_RowWaveButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// Elle bondit hors du rond, tient un instant en l'air, puis retombe en
  /// dépassant. Le pic est à 2,1 — beaucoup, volontairement : l'emoji sort de
  /// son cercle de 38 px et c'est CE débordement qui fait qu'on voit le geste
  /// partir depuis l'autre bout de l'écran. Un bouton qui frémit ne dit rien.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 2.1)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 22,
    ),
    TweenSequenceItem(tween: ConstantTween<double>(2.1), weight: 26),
    TweenSequenceItem(
      tween: Tween(begin: 2.1, end: 1.0)
          .chain(CurveTween(curve: Curves.elasticOut)),
      weight: 52,
    ),
  ]).animate(_c);

  /// Le vrai bond : `_scale` grossit symétriquement autour du centre, donc
  /// SEUL ce décalage vers le haut fait que l'emoji "monte" au lieu de
  /// juste gonfler sur place. Mêmes poids/courbes que `_scale` — elle monte
  /// pendant qu'elle grossit, tient en l'air, retombe en même temps qu'elle
  /// rapetisse.
  late final Animation<double> _lift = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: -16.0)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 22,
    ),
    TweenSequenceItem(tween: ConstantTween<double>(-16.0), weight: 26),
    TweenSequenceItem(
      tween: Tween(begin: -16.0, end: 0.0)
          .chain(CurveTween(curve: Curves.elasticOut)),
      weight: 52,
    ),
  ]).animate(_c);

  /// Et elle salue vraiment : cinq allers-retours à presque un radian, qui
  /// s'amortissent. L'amplitude décroît avec le temps (le `1 - t`), sinon la
  /// main vibre au lieu de saluer.
  late final Animation<double> _wobble = _c.drive(
    TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 14),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 86),
    ]),
  );

  /// Le verre s'allume au passage — un souffle de cyan dans le dépoli, le
  /// temps du salut. C'est ce qui rattache le geste À CETTE ligne quand
  /// l'emoji, lui, a débordé du rond.
  late final Animation<double> _flash = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 85),
  ]).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _tap() {
    // Même à sec le bouton répond : sans retour au doigt on croit que le tap
    // n'a pas pris. C'est le message qui dit pourquoi, pas l'inertie.
    if (widget.enabled && !widget.busy) {
      HapticFeedback.mediumImpact();
      _c.forward(from: 0);
    }
    widget.onWave();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.enabled && !widget.busy;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      // L'emoji dépasse largement du rond pendant le salut. La pile ne clippe
      // pas (`Clip.none` est le défaut d'un Stack) et le SizedBox garde la
      // ligne à 38 px : le débordement est purement peint, il ne pousse rien.
      child: SizedBox(
        width: 38,
        height: 38,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _wobble.value;
            // sin de cinq tours, amorti : part à droite, revient, et meurt.
            final angle =
                t == 0 ? 0.0 : 0.95 * (1 - t) * math.sin(t * math.pi * 10);
            return Stack(
              alignment: Alignment.center,
              children: [
                // Le verre reste à sa taille : c'est le socle, il ne bouge
                // pas. Seul ce qu'il y a dessus s'agite.
                ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color.lerp(
                          live ? SC.glassStrong : SC.glass,
                          SC.accent.withValues(alpha: 0.55),
                          _flash.value,
                        ),
                        border: Border.all(
                          color: Color.lerp(
                            live ? SC.glassBorder : SC.glass,
                            SC.accent,
                            _flash.value,
                          )!,
                        ),
                      ),
                    ),
                  ),
                ),
                Transform.translate(
                  offset: Offset(0, _lift.value),
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Transform.rotate(
                      angle: angle,
                      child: Opacity(
                        opacity: live ? 1 : 0.45,
                        child: const Text(
                          '👋',
                          style: TextStyle(fontSize: 18, height: 1.15),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Le titre d'une section : une étiquette en petites capitales à chasse fixe,
/// et son compte. La pastille pleine a disparu — deux badges cyan (celui de la
/// section, celui de la ligne) se disputaient l'œil pour dire la même chose.
///
/// Deux formes selon ce que le compte veut dire. Pour les matchs il ouvre le
/// titre ([countLeads]) — « 3 NOUVEAUX MATCHS », c'est un stock. Pour les
/// messages il le suit en cyan — « MESSAGES · 3 non lus », c'est un reste à
/// traiter, et le titre reste lisible quand il tombe à zéro.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.count,
    this.countLeads = false,
  });

  final String label;
  final int count;
  final bool countLeads;

  static const TextStyle _label = TextStyle(
    fontFamily: _kMono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
  );

  @override
  Widget build(BuildContext context) {
    final title = label.toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: countLeads
          ? Text(
              count > 0 ? '$count $title' : title,
              style: _label.copyWith(color: SC.accent),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  title,
                  style: _label.copyWith(
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    AppStrings.t('chat_unread_count', args: {'n': '$count'}),
                    style: _label.copyWith(
                      color: SC.accent,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// The horizontal rail of match bubbles: one circle per match you haven't
/// written to yet, newest first, name underneath. Tapping one opens the
/// conversation — which is exactly what moves it out of the rail.
class _MatchBubbleRail extends StatelessWidget {
  const _MatchBubbleRail({
    required this.matches,
    required this.seen,
    required this.onTap,
  });

  final List<RemoteProfile> matches;

  /// Les matchs déjà regardés : ils restent dans le rail, sans anneau.
  final Set<String> seen;
  final void Function(RemoteProfile) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // La bulle, son anneau, et le prénom dessous.
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: matches.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (ctx, i) => _MatchBubble(
          profile: matches[i],
          seen: seen.contains(matches[i].id),
          onTap: () => onTap(matches[i]),
        ),
      ),
    );
  }
}

class _MatchBubble extends StatelessWidget {
  const _MatchBubble({
    required this.profile,
    required this.seen,
    required this.onTap,
  });

  final RemoteProfile profile;

  /// Déjà vu : l'anneau tombe et la bulle s'estompe. Elle reste là — le match
  /// n'a pas disparu, c'est la nouveauté qui s'est éteinte.
  final bool seen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final firstName = profile.displayName.trim().split(RegExp(r'\s+')).first;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: seen ? 0.55 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // L'anneau cyan→vert du match pas encore regardé. Il est peint SOUS
            // la photo, qui garde un liseré de fond entre les deux : sans ça
            // le dégradé touche le visage et se lit comme une bordure.
            Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: seen
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [SC.accent, SC.online],
                      ),
              ),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: SC.bg, width: 2),
                ),
                child: ProfileAvatar(
                  displayName: profile.displayName,
                  avatarUrl: profile.avatarUrl,
                  size: 56,
                ),
              ),
            ),
            const SizedBox(height: 7),
            SizedBox(
              width: 64,
              child: Text(
                firstName,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: seen ? SC.textMuted : SC.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatListSkeleton extends StatefulWidget {
  const _ChatListSkeleton();

  @override
  State<_ChatListSkeleton> createState() => _ChatListSkeletonState();
}

class _ChatListSkeletonState extends State<_ChatListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same panel (fills + hugs the nav at rest) as the loaded list, with
    // shimmering placeholder rows so the layout doesn't shift when data lands.
    final navBody = GlassNavBar.height + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fill = constraints.maxHeight - 12 - navBody;
        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.only(top: 12, bottom: navBody),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: fill > 0 ? fill : 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (_, _) {
                    final t = Curves.easeInOut.transform(_ctrl.value);
                    // 0.10 → 0.18 alpha so the shimmer breathes gently.
                    final shimmer =
                        Colors.white.withValues(alpha: 0.10 + 0.08 * t);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 5; i++)
                          _SkeletonRow(shimmer: shimmer),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.shimmer});

  final Color shimmer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          // Avatar placeholder — same 46 px circle the real row uses.
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: shimmer,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 120,
                  height: 14,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 180,
                  height: 10,
                  decoration: BoxDecoration(
                    color: shimmer,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Timestamp bar.
          Container(
            width: 28,
            height: 10,
            decoration: BoxDecoration(
              color: shimmer,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(width: 8),
          // Phone-button placeholder.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: shimmer,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoFriendsEmpty extends StatelessWidget {
  const _NoFriendsEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: SC.menu,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.people_outline,
                color: SC.textMuted,
                size: 34,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('chat_no_friends_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('chat_no_friends_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: SC.textMuted,
                  fontSize: 13,
                  height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
