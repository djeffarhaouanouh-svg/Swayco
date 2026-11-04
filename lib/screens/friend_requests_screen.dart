import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../widgets/tap_pad.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/device_id.dart';
import '../services/friend_request_unread.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
import '../services/likes_empty_kind.dart';
import '../services/locations.dart';
import '../services/match_celebration.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/swayco_sounds.dart';
import '../services/supabase_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/appear.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/nav_auto_hide.dart';
import '../widgets/likes_lock.dart';
import '../widgets/match_overlay.dart';
import '../widgets/popup_kit.dart' show popupDisplay;
import '../widgets/profile_avatar.dart';
import 'chat_thread_screen.dart';
import 'paywall_screen.dart' show showBoostPaywall;
import 'profile_screen.dart';


/// Demandes — the people who liked me. Accepting is the match (the two likes
/// meet and the conversation opens); refusing drops the like. Accepted rows
/// disappear from here and surface on the Chat list.
class FriendRequestsScreen extends StatefulWidget {
  const FriendRequestsScreen({super.key});

  @override
  State<FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<FriendRequestsScreen>
    with WidgetsBindingObserver {
  String _myId = '';
  /// Cartes en train de sortir (accepte / refuse) : elles s'effacent avant
  /// que la grille se referme.
  final Set<String> _leaving = {};
  List<IncomingFriendRequest> _requests = const [];
  // Profiles who liked one of my photos, newest first.
  LikesLock? _lock;
  bool _loading = true;
  String? _error;

  /// Pourquoi la liste est vide (page Likes, 3 états vides).
  LikesEmptyKind _emptyKind = LikesEmptyKind.never;

  /// Mon profil est déjà boosté : l'état « calme aujourd'hui » n'en propose pas.
  bool _boosted = false;
  RealtimeChannel? _channel;
  // Likes + photo-reactions have no realtime subscription (only friendships
  // do), so while the user sits on this tab we poll to pull fresh ones in.
  // Runs only while Demandes is the active tab and the app is foregrounded.
  Timer? _livePoll;
  static const _livePollInterval = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // This screen lives in RootShell's IndexedStack (always built), so
    // refresh its list each time the user actually lands on the Demandes
    // tab — that's when a fresh like / reaction should appear.
    NavTab.index.addListener(_onNavTabChanged);
    _bootstrap();
  }

  void _onNavTabChanged() {
    if (!mounted) return;
    if (NavTab.index.value == NavTab.demandes) {
      _reload(silent: true);
      _startLivePoll();
    } else {
      _stopLivePoll();
    }
  }

  /// Keep likes / reactions fresh while the user lingers on this tab — they
  /// have no realtime channel, so without this a new one wouldn't show until
  /// the tab is re-opened. Idempotent.
  void _startLivePoll() {
    _livePoll ??= Timer.periodic(_livePollInterval, (_) {
      if (mounted) _reload(silent: true);
    });
  }

  void _stopLivePoll() {
    _livePoll?.cancel();
    _livePoll = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NavTab.index.removeListener(_onNavTabChanged);
    _stopLivePoll();
    final ch = _channel;
    if (ch != null) {
      Supabase.instance.client.removeChannel(ch);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload(silent: true);
      // Resume polling only if Demandes is the tab we came back to.
      if (NavTab.index.value == NavTab.demandes) _startLivePoll();
    } else if (state == AppLifecycleState.paused) {
      // No point polling in the background — the OS push handles waking us.
      _stopLivePoll();
    }
  }

  Future<void> _bootstrap() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    await _reload();
    // If the user launched straight onto Demandes, start the live poll now
    // (the NavTab listener only fires on a *change* of tab).
    if (NavTab.index.value == NavTab.demandes) _startLivePoll();
    if (!isSupabaseReady || id.isEmpty) return;
    _channel = FriendshipApi.subscribeMine(
      userId: id,
      onChange: () => _reload(silent: true),
    );
  }

  Future<void> _reload({bool silent = false}) async {
    if (_myId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _requests = const [];
      });
      return;
    }
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final friendships = await FriendshipApi.fetchIncomingPendingWithProfiles(
        _myId,
      );
      final lock = await LikesLock.load(_myId);
      // Liste vide : pourquoi ? Rien n'est lu quand il y a des demandes.
      var emptyKind = _emptyKind;
      var boosted = _boosted;
      if (friendships.isEmpty) {
        final stamps = await FriendshipApi.fetchIncomingStamps(_myId);
        // Lecture ratée : on garde l'écran affiché, on ne devine pas.
        if (stamps.ok) {
          emptyKind = classifyLikesEmpty(
            lastReceived: stamps.lastReceived,
            lastAnswered: stamps.lastAnswered,
            now: DateTime.now(),
          );
        }
        if (stamps.ok && emptyKind == LikesEmptyKind.quietToday) {
          try {
            boosted = (await ProfileApi.fetchById(_myId))?.isBoosted ?? false;
          } catch (_) {}
        }
      }
      if (!mounted) return;
      setState(() {
        _requests = friendships;
        _lock = lock;
        _emptyKind = emptyKind;
        _boosted = boosted;
        _loading = false;
      });
      FriendRequestUnread.setCount(friendships.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Accepting a like IS the match — the celebration fires right here.
  Future<void> _accept(IncomingFriendRequest req) async {
    HapticFeedback.mediumImpact();
    SwaycoSounds.play(SwSound.friendAccepted);
    // La carte se retire d'abord en douceur ; les autres glissent ensuite
    // vers le haut pour combler la place.
    setState(() => _leaving.add(req.friendship.id));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    final next = _requests
        .where((r) => r.friendship.id != req.friendship.id)
        .toList();
    setState(() {
      _leaving.remove(req.friendship.id);
      _requests = next;
      // La dernière vient d'être traitée : « Tu es à jour ! » tout de suite.
      if (next.isEmpty) _emptyKind = LikesEmptyKind.caughtUp;
    });
    FriendRequestUnread.setCount(next.length);
    try {
      await FriendshipApi.accept(req.friendship.id);
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'requests', 'kind': 'match'},
      );
      if (!mounted) return;
      await _celebrateMatch(req.requester);
    } catch (e) {
      if (!mounted) return;
      setState(() => _requests = [..._requests, req]);
      FriendRequestUnread.setCount(_requests.length);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// "It's a match!" over the Demandes list. "Dis bonjour" opens the DM.
  Future<void> _celebrateMatch(RemoteProfile? peer) async {
    if (peer == null) return;
    MatchCelebration.markShown(peer.id);
    final me = isSupabaseReady ? await ProfileApi.fetchById(_myId) : null;
    if (!mounted) return;
    final meProfile = me ??
        RemoteProfile(
          id: _myId,
          handle: '',
          displayName: '',
          language: AppStrings.currentBcp47.value,
          avatarColor: '',
          avatarUrl: '',
        );
    final peerName = peer.displayName.trim().isEmpty
        ? AppStrings.t('profile_anonymous')
        : peer.displayName;
    await showMatchOverlay(
      context,
      me: meProfile,
      peer: peer,
      onSayHi: () {
        final ids = [_myId, peer.id]..sort();
        Navigator.of(context).push<void>(
          chatThreadRoute(
            builder: (_) => ChatThreadScreen(
              conversationId: 'dm-${ids[0]}-${ids[1]}',
              title: peerName,
              peerDeviceId: peer.id,
            ),
          ),
        );
      },
    );
  }

  Future<void> _reject(IncomingFriendRequest req) async {
    HapticFeedback.lightImpact();
    SwaycoSounds.play(SwSound.pass);
    // La carte se retire d'abord en douceur ; les autres glissent ensuite
    // vers le haut pour combler la place.
    setState(() => _leaving.add(req.friendship.id));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    final next = _requests
        .where((r) => r.friendship.id != req.friendship.id)
        .toList();
    setState(() {
      _leaving.remove(req.friendship.id);
      _requests = next;
      if (next.isEmpty) _emptyKind = LikesEmptyKind.caughtUp;
    });
    FriendRequestUnread.setCount(next.length);
    try {
      await FriendshipApi.reject(req.friendship.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _requests = [..._requests, req]);
      FriendRequestUnread.setCount(_requests.length);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Après l'achat d'un boost, le webhook le crédite quelques secondes plus tard :
  /// on relit mon profil jusqu'à ce qu'il soit boosté (même principe que l'écran
  /// profil), pour que « calme aujourd'hui » cesse de le proposer.
  Future<void> _awaitBoostCredit() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final me = await ProfileApi.fetchById(_myId);
        if (!mounted) return;
        if (me != null && me.isBoosted) {
          setState(() => _boosted = true);
          return;
        }
      } catch (_) {}
    }
  }

  void _openProfile(RemoteProfile peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: peer.id)),
    );
  }

  /// La barre du bas se range pendant que la liste défile, et revient 0,9 s
  /// après l'arrêt (NavAutoHide enveloppe tout l'écran).
  @override
  Widget build(BuildContext context) =>
      NavAutoHide(tab: NavTab.demandes, child: _buildScaffold(context));

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.tabBg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Même bande que « Messages » (chat_screen._titleBar) : mêmes marges,
            // même hauteur (40), même titre (26 / 800 / -0,3), même trait
            // dessous. Le titre ne bouge plus quand on passe d'un onglet à l'autre.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
              child: SizedBox(
                height: 40,
                child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('demandes_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // La police d'origine de ce titre (Bricolage Grotesque,
                      // 30 / 800), reprise à l'identique sur Messages.
                      style: SCText.h1,
                    ),
                  ),
                  // Pastille : le nombre de likes recus, en haut a droite.
                  if (!_loading)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: SC.accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.favorite_rounded,
                            size: 16,
                            color: SC.onAccent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_requests.length}',
                            style: const TextStyle(
                              color: SC.onAccent,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              ),
            ),
            // Le liseré qui ferme l'en-tête, comme sur Messages : pleine largeur.
            Divider(
              height: 1,
              thickness: 1,
              color: SC.stroke.withValues(alpha: 0.10),
            ),
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: RevenueCat.proActive,
                builder: (_, _, _) => _buildBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: SC.accentFg));
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
    // Every category flattened into one list of rows — each its own floating
    // card, in priority order: incoming likes (need a decision) → photo likes.
    // Without Pro (or a video unlock for that liker) the PDP is blurred, the
    // name hidden, and tapping opens the unlock sheet instead of the profile.
    bool revealed(RemoteProfile? p) =>
        p != null && (_lock?.isRevealed(p.id) ?? false);
    void openOrUnlock(RemoteProfile? p) {
      if (p == null) return;
      if (revealed(p)) {
        _openProfile(p);
        return;
      }
      // The paywall's wall + "N people liked you": everyone who liked me,
      // requests and photo likes alike, each person once.
      final seen = <String>{};
      showLikesUnlockSheet(
        context,
        myId: _myId,
        profile: p,
        likers: [
          for (final q in [for (final r in _requests) r.requester, ])
            if (q != null && seen.add(q.id)) q,
        ],
        onRevealed: () {
          if (mounted) setState(() => _lock?.unlocked.add(p.id));
        },
      );
    }

    final rows = <Widget>[
      for (final req in _requests)
        if (revealed(req.requester))
          _RevealedTile(
            request: req,
            leaving: _leaving.contains(req.friendship.id),
            onOpenProfile: () => openOrUnlock(req.requester),
            onAccept: () => _accept(req),
            onReject: () => _reject(req),
          )
        else
          _RequestTile(
            request: req,
            leaving: _leaving.contains(req.friendship.id),
            revealed: false,
            onOpenProfile: () => openOrUnlock(req.requester),
            // Verrou : sur une carte floutée, « Add » ouvre l'écran Pro / vidéo
            // au lieu d'accepter (accepter = match = voir qui c'est : le flou
            // ne servait à rien). Une fois la personne révélée, « Add » marche.
            onAccept: () => openOrUnlock(req.requester),
            onReject: () => _reject(req),
          ),
    ];
    final navBody = GlassNavBar.totalReservedHeight + MediaQuery.paddingOf(context).bottom;
    return RefreshIndicator(
      color: SC.accentFg,
      backgroundColor: SC.menu,
      onRefresh: _reload,
      child: rows.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: navBody),
              children: [
                Padding(
                  // Remonté : 40 en haut au lieu de 80 (les trois états vides
                  // partagent ce réglage).
                  padding: const EdgeInsets.only(top: 40, bottom: 80),
                  child: _NoRequestsEmpty(
                    kind: _emptyKind,
                    boosted: _boosted,
                    onDiscover: () => NavTab.select(NavTab.discover),
                    onProfile: () => NavTab.select(NavTab.profile),
                    onBoost: () => showBoostPaywall(
                      context,
                      onPurchased: _awaitBoostCredit,
                    ),
                  ),
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, c) {
                // Grille a la main : chaque carte est un AnimatedPositioned, donc
                // quand l'une part, les suivantes glissent vers le haut.
                const gap = 10.0;
                final tile = (c.maxWidth - 32 - gap) / 2;
                final rowsCount = (rows.length + 1) ~/ 2;
                final height = rowsCount * tile + (rowsCount - 1) * gap;
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(16, 4, 16, navBody + 8),
                  child: SizedBox(
                    height: height,
                    child: Stack(
                      children: [
                        for (var i = 0; i < rows.length; i++)
                          AnimatedPositioned(
                            key: ValueKey(_requests[i].friendship.id),
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeOutCubic,
                            left: (i % 2) * (tile + gap),
                            top: (i ~/ 2) * (tile + gap),
                            width: tile,
                            height: tile,
                            child: FadeSlideIn(
                              delay: Duration(milliseconds: i * 55),
                              child: rows[i],
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Une demande en carre : la premiere photo de la galerie en plein cadre
/// (floutee tant que la personne n'est pas revelee), drapeau en haut a gauche,
/// prenom (ou « Quelqu'un ») et boutons Add / ✕ en bas.
class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.request,
    required this.revealed,
    required this.onOpenProfile,
    required this.onAccept,
    required this.onReject,
    this.leaving = false,
  });

  final IncomingFriendRequest request;
  final bool leaving;
  final bool revealed;
  final VoidCallback onOpenProfile;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  /// La premiere photo de la galerie ; a defaut la photo Discover, puis l'avatar.
  static String _photoOf(RemoteProfile? p) {
    if (p == null) return '';
    for (final u in p.photos) {
      if (u.isNotEmpty) return u;
    }
    if (p.discoverPhotoUrl.isNotEmpty) return p.discoverPhotoUrl;
    return p.avatarUrl;
  }

  @override
  Widget build(BuildContext context) {
    final p = request.requester;
    final photo = _photoOf(p);
    final name = !revealed
        ? AppStrings.t('likes_someone')
        : p?.displayName.isNotEmpty == true
            ? p!.displayName
            : (p?.handle.isNotEmpty == true
                ? '@${p!.handle}'
                : AppStrings.t('chat_no_name'));
    final flag = p == null
        ? ''
        : countryFlagFor(p.country) ??
            findLanguageByCode(p.language)?.flag ??
            '';
    Widget image() {
      if (photo.isEmpty) {
        return ColoredBox(
          color: SC.menu,
          child: Center(
            child: revealed
                ? ProfileAvatar(
                    displayName: p?.displayName ?? '',
                    avatarUrl: p?.avatarUrl,
                    size: 72,
                  )
                : BlurredAvatar(profile: p, size: 72),
          ),
        );
      }
      final img = Image.network(
        photo,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => ColoredBox(color: SC.menu),
      );
      if (revealed) return img;
      // Floute, et agrandi un peu pour que le flou ne laisse pas de bord clair.
      return Transform.scale(
        scale: 1.15,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: img,
        ),
      );
    }

    return AnimatedOpacity(
      opacity: leaving ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: AnimatedScale(
        scale: leaving ? 0.85 : 1,
        duration: const Duration(milliseconds: 200),
        child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpenProfile,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image(),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xD9000000)],
                  stops: [0.4, 1],
                ),
              ),
            ),
            if (!revealed)
              const Center(
                child: Icon(Icons.lock_rounded, color: Colors.white, size: 30),
              ),
            if (flag.isNotEmpty)
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                  child: Text(flag, style: const TextStyle(fontSize: 15)),
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _AcceptButton(onTap: onAccept),
                      const SizedBox(width: 4),
                      _RejectButton(onTap: onReject),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}

/// Tuile d'un like REVELE (Pro, femme ou debloque par pub) — V2 « bouton pleine
/// largeur » : photo en plein cadre sous un voile sombre, drapeau rond en haut
/// a gauche, refuser (rouge transparent) en haut a droite, prenom + age, ville
/// et un grand bouton « Ajouter » en bas.
class _RevealedTile extends StatelessWidget {
  const _RevealedTile({
    required this.request,
    required this.onOpenProfile,
    required this.onAccept,
    required this.onReject,
    this.leaving = false,
  });

  final IncomingFriendRequest request;
  final bool leaving;
  final VoidCallback onOpenProfile;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final p = request.requester;
    final photo = _RequestTile._photoOf(p);
    final name = p?.displayName.isNotEmpty == true
        ? p!.displayName
        : (p?.handle.isNotEmpty == true
            ? '@${p!.handle}'
            : AppStrings.t('chat_no_name'));
    final age = p?.age;
    final city = (p?.city.trim().isNotEmpty ?? false)
        ? p!.city.trim()
        : (p?.country.trim() ?? '');
    final country = p?.country.trim() ?? '';
    final iso = countryIso2For(country);
    final emoji = country.isEmpty ? null : countryFlagFor(country);
    final initial = (p?.displayName.trim().isNotEmpty ?? false)
        ? p!.displayName.trim().characters.first.toUpperCase()
        : '?';

    return AnimatedOpacity(
      opacity: leaving ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: AnimatedScale(
        scale: leaving ? 0.85 : 1,
        duration: const Duration(milliseconds: 200),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpenProfile,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              boxShadow: SC.light
                  ? const [
                      BoxShadow(
                        color: Color(0x591F5EFF),
                        blurRadius: 22,
                        spreadRadius: -10,
                        offset: Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: LayoutBuilder(
                builder: (context, c) => Stack(
                  fit: StackFit.expand,
                  children: [
                    if (photo.isNotEmpty)
                      Image.network(
                        photo,
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, -0.6),
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: Color(0xFF1A2040)),
                      )
                    else ...[
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFF1A2040), Color(0xFF10121C)],
                          ),
                        ),
                      ),
                      Positioned(
                        top: c.maxHeight * 0.27,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            width: 66,
                            height: 66,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFFEC4899), Color(0xFF9D2B6B)],
                              ),
                            ),
                            child: Text(
                              initial,
                              style: popupDisplay(
                                fontSize: 28,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    // Voile : toujours present, le texte blanc doit rester lisible.
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00040A1E), Color(0xE0040A1E)],
                          stops: [0.38, 1],
                        ),
                      ),
                    ),
                    if (iso.isNotEmpty || emoji != null)
                      Positioned(
                        left: 10,
                        top: 10,
                        child: Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x8C04123A),
                            border: Border.all(
                              color: const Color(0x59FFFFFF),
                              width: 1.5,
                            ),
                          ),
                          child: iso.isNotEmpty
                              ? ClipOval(
                                  child: Image.network(
                                    'https://flagcdn.com/w80/${iso.toLowerCase()}.png',
                                    width: 17,
                                    height: 17,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Text(
                                      emoji ?? '',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1,
                                      ),
                                    ),
                                  ),
                                )
                              : Text(
                                  emoji ?? '',
                                  style: const TextStyle(fontSize: 14, height: 1),
                                ),
                        ),
                      ),
                    Positioned(
                      right: 10,
                      top: 10,
                      child: PadTap(
                        behavior: HitTestBehavior.opaque,
                        onTap: onReject,
                        child: Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x80EF4444),
                            border: Border.all(color: const Color(0xD9EF4444)),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: popupDisplay(
                                    fontSize: 16,
                                    letterSpacing: -0.5,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              if (age != null) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '$age',
                                  maxLines: 1,
                                  style: popupDisplay(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white.withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (city.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              city,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onAccept,
                            child: Container(
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: SC.accent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                AppStrings.t('add_friend_short'),
                                maxLines: 1,
                                style: popupDisplay(
                                  fontSize: 13,
                                  color: SC.onAccent,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// IDs whose pop-in has already played this session, so a notification's emoji
/// jumps only the FIRST time it's seen (not on every tab revisit).
final Set<String> _poppedEmojiIds = <String>{};

/// One segment of the emoji's damped left-right shake (radians).
TweenSequenceItem<double> _wiggle(double begin, double end, double weight) =>
    TweenSequenceItem(
      tween: Tween(begin: begin, end: end)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: weight,
    );

/// An emoji that, the first time it's seen, does a little dopamine "wiggle":
/// a quick pop + a damped left-right shake (it jiggles, not just hops up).
/// Subsequent appearances render statically (one-shot per id, per session).
class _PopInEmoji extends StatefulWidget {
  const _PopInEmoji({
    required this.id,
    required this.emoji,
    this.fontSize = 26,
  });

  final String id;
  final String emoji;
  final double fontSize;

  @override
  State<_PopInEmoji> createState() => _PopInEmojiState();
}

class _PopInEmojiState extends State<_PopInEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
    // Settled by default; only the very first sighting plays the wiggle.
    value: 1.0,
  );
  // A small pop so it has some life…
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.18)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 18,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.18, end: 1.0)
          .chain(CurveTween(curve: Curves.easeIn)),
      weight: 82,
    ),
  ]).animate(_c);
  // …and a damped left-right shake (radians) — the "remue".
  late final Animation<double> _rot = TweenSequence<double>([
    _wiggle(0.0, 0.24, 12),
    _wiggle(0.24, -0.21, 16),
    _wiggle(-0.21, 0.15, 16),
    _wiggle(0.15, -0.11, 14),
    _wiggle(-0.11, 0.06, 14),
    _wiggle(0.06, -0.03, 12),
    _wiggle(-0.03, 0.0, 16),
  ]).animate(_c);

  @override
  void initState() {
    super.initState();
    // Set.add returns true only when the id is new → first sighting → jump.
    if (_poppedEmojiIds.add(widget.id)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Transform.rotate(
        angle: _rot.value,
        child: Transform.scale(scale: _scale.value, child: child),
      ),
      child: Text(widget.emoji, style: TextStyle(fontSize: widget.fontSize)),
    );
  }
}

class _AcceptButton extends StatelessWidget {
  const _AcceptButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.accent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            AppStrings.t('add_friend_short'),
            style: const TextStyle(
              color: Color(0xFF0A1024),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _RejectButton extends StatelessWidget {
  const _RejectButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: PadInkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(6),
          child: Icon(
            Icons.close_rounded,
            color: Colors.white.withValues(alpha: 0.85),
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// La liste est vide : pourquoi ? (Likes, 3 états — maquettes 1a / 1b / 1c.)
///   never      aucune demande reçue, jamais ;
///   caughtUp   tout est traité, et au moins une demande est arrivée aujourd'hui ;
///   quietToday des demandes passées, aucune aujourd'hui (on propose un boost).
class _NoRequestsEmpty extends StatelessWidget {
  const _NoRequestsEmpty({
    required this.kind,
    required this.boosted,
    required this.onDiscover,
    required this.onBoost,
    required this.onProfile,
  });

  final LikesEmptyKind kind;

  /// Mon profil est déjà boosté : pas de pastille d'argument ni de bouton.
  final bool boosted;
  final VoidCallback onDiscover;
  final VoidCallback onBoost;

  /// 1a : « Poster ma photo » renvoie sur l'onglet Profil.
  final VoidCallback onProfile;

  /// Un rond qui bat doucement : 1 → 1,06, une impulsion toutes les ~660 ms.
  static Widget _beat(Widget child) => Breathing(
        minScale: 1.0,
        maxScale: 1.06,
        period: const Duration(milliseconds: 330),
        child: child,
      );

  Widget _iconCircle(IconData icon, {required bool beat}) {
    final circle = Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        color: SC.accent.withValues(alpha: 0.13),
        shape: BoxShape.circle,
        border: Border.all(color: SC.accent.withValues(alpha: 0.35)),
      ),
      // accentFg : jaune en sombre, bleu de marque en clair (du jaune sur fond
      // clair ne se lit pas).
      child: Icon(icon, color: SC.accentFg, size: 40),
    );
    return beat ? _beat(circle) : Breathing(child: circle);
  }

  @override
  Widget build(BuildContext context) {
    final (titleKey, bodyKey) = switch (kind) {
      LikesEmptyKind.never => ('demandes_empty_title', 'demandes_never_body'),
      LikesEmptyKind.caughtUp => ('demandes_caught_title', 'demandes_caught_body'),
      LikesEmptyKind.quietToday => ('demandes_quiet_title', 'demandes_quiet_body'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            switch (kind) {
              LikesEmptyKind.never =>
                _iconCircle(Icons.person_add_rounded, beat: false),
              LikesEmptyKind.caughtUp =>
                _iconCircle(Icons.done_all_rounded, beat: true),
              LikesEmptyKind.quietToday => const _FlagOrbit(),
            },
            const SizedBox(height: 22),
            Text(
              AppStrings.t(titleKey),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textPrimary,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                AppStrings.t(bodyKey),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: SC.textMuted,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            if (kind == LikesEmptyKind.never) ...[
              const SizedBox(height: 24),
              _EmptyCta(
                icon: Icons.add_a_photo_rounded,
                label: AppStrings.t('demandes_never_cta'),
                onTap: onProfile,
              ),
            ],
            if (kind == LikesEmptyKind.caughtUp) ...[
              const SizedBox(height: 24),
              _EmptyCta(
                icon: Icons.public_rounded,
                label: AppStrings.t('demandes_caught_cta'),
                onTap: onDiscover,
              ),
            ],
            if (kind == LikesEmptyKind.quietToday && !boosted) ...[
              const SizedBox(height: 18),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: SC.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: SC.accent.withValues(alpha: 0.40)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.trending_up_rounded,
                        size: 20, color: SC.accentFg),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        AppStrings.t('demandes_quiet_perk'),
                        style: TextStyle(
                          color: SC.accentFg,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _EmptyCta(
                icon: Icons.bolt_rounded,
                label: AppStrings.t('boost_my_profile'),
                onTap: onBoost,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Le bouton jaune des états « à jour » et « calme aujourd'hui » : 48 de haut,
/// pastille complète, texte foncé sur `SC.accent`, ombre jaune douce.
class _EmptyCta extends StatelessWidget {
  const _EmptyCta({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PadTap(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: SC.accent,
            borderRadius: BorderRadius.circular(99),
            boxShadow: [
              BoxShadow(
                color: SC.accent.withValues(alpha: 0.22),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: SC.onAccent),
              const SizedBox(width: 8),
              // Flexible : un libellé long (allemand, russe) se coupe au lieu de
              // déborder du bouton.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SC.onAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 1c : un cœur dans un rond de marque, et cinq drapeaux qui tournent autour sur
/// une ellipse de 240 × 76 (9 s, sens anti-horaire). Celui de devant est un peu
/// plus grand et opaque, ceux de derrière plus petits, à 70 %, et passent
/// DERRIÈRE le cœur. Une ellipse pointillée marque le trajet. 230 px de haut.
class _FlagOrbit extends StatefulWidget {
  const _FlagOrbit();

  @override
  State<_FlagOrbit> createState() => _FlagOrbitState();
}

class _FlagOrbitState extends State<_FlagOrbit>
    with SingleTickerProviderStateMixin {
  static const _flags = ['jp', 'br', 'se', 'es', 'co'];
  static const double _w = 300, _h = 230, _a = 120, _b = 38, _flag = 44;

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // « Réduire les animations » : les drapeaux restent en place.
    if (MediaQuery.disableAnimationsOf(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Widget _flagAt(int i, double t) {
    // Décroissant : à l'écran (y vers le bas) c'est le sens anti-horaire.
    final theta = 2 * math.pi * (i / _flags.length) - 2 * math.pi * t;
    final depth = (math.sin(theta) + 1) / 2; // 0 = tout derrière, 1 = devant
    final scale = 0.78 + (1.06 - 0.78) * depth;
    final x = _w / 2 + _a * math.cos(theta) - _flag / 2;
    final y = _h / 2 + _b * math.sin(theta) - _flag / 2;
    return Positioned(
      left: x,
      top: y,
      child: Opacity(
        opacity: 0.7 + 0.3 * depth,
        child: Transform.scale(
          scale: scale,
          child: Container(
            width: _flag,
            height: _flag,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: SC.menu,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipOval(
              child: Image.network(
                'https://flagcdn.com/w80/${_flags[i]}.png',
                width: _flag,
                height: _flag,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _w,
      height: _h,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) {
          final t = _spin.value;
          // Le profil de chaque drapeau : devant (sin >= 0, du côté du
          // spectateur) ou derrière.
          bool front(int i) =>
              math.sin(2 * math.pi * (i / _flags.length) - 2 * math.pi * t) >=
              0;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Le trajet : une ellipse pointillée, 1 px.
              Positioned.fill(
                child: CustomPaint(
                  painter: _DashedEllipsePainter(
                    a: _a,
                    b: _b,
                    color: SC.fg.withValues(alpha: 0.2),
                  ),
                ),
              ),
              for (var i = 0; i < _flags.length; i++)
                if (!front(i)) _flagAt(i, t),
              // Le cœur, qui bat.
              Center(
                child: _NoRequestsEmpty._beat(
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      gradient: SC.brandGradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: SC.brandBlue.withValues(alpha: 0.55),
                          blurRadius: 40,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.favorite_rounded,
                      size: 44,
                      color: SC.accent,
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < _flags.length; i++)
                if (front(i)) _flagAt(i, t),
            ],
          );
        },
      ),
    );
  }
}

class _DashedEllipsePainter extends CustomPainter {
  _DashedEllipsePainter({required this.a, required this.b, required this.color});

  final double a;
  final double b;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addOval(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: a * 2,
          height: b * 2,
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = true;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), paint);
        d += 9; // 4 de trait, 5 d'espace
      }
    }
  }

  @override
  bool shouldRepaint(_DashedEllipsePainter old) =>
      old.a != a || old.b != b || old.color != color;
}
