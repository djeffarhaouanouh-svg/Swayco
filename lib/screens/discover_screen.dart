import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics.dart';
import '../services/app_boot.dart';
import '../services/app_strings.dart';
import '../services/device_id.dart';
import '../services/fact_emojis.dart';
import '../services/friendship_api.dart';
import '../services/interests.dart';
import '../services/job_sectors.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/looking_for.dart';
import '../services/match_celebration.dart';
import '../services/persona_categories.dart';
import '../services/nav_chrome.dart';
import '../services/profile_api.dart';
import '../services/presence_service.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../services/zodiac.dart';
import '../theme/swayco_theme.dart';
import '../widgets/flag_border.dart';
import '../widgets/flag_gradients.dart';
import '../widgets/glass.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/interest_chip.dart';
import '../widgets/match_overlay.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/translated_profile_text.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

/// Le fond du panneau déplié : opaque, un cran au-dessus du noir de la page —
/// assez pour qu'on voie où il commence quand il recouvre la photo, assez peu
/// pour rester du noir.
const Color _kPanelBg = Color(0xFF141517);

/// Marge latérale du bloc Discover (carte + bande blanche). Les deux DOIVENT
/// la partager, sinon leurs bords ne s'alignent plus.
const double _kCardInset = 16.0;

/// Rayon des coins de la carte photo — et de ce qui doit s'y raccorder.
const double _kCardRadius = 28.0;

// ══════════════════════════════════════════════════════════════════════════════
// DiscoverScreen
// ══════════════════════════════════════════════════════════════════════════════

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<RemoteProfile> _profiles = const [];
  bool _feedLoading = true;
  final List<({RemoteProfile profile, List<String> photos})> _cards = [];

  void _rebuildCards() {
    _cards.clear();
    for (final p in _profiles) {
      var photos = p.photos.where((u) => u.isNotEmpty).toList();
      if (photos.isEmpty && p.discoverPhotoUrl.isNotEmpty) {
        photos = [p.discoverPhotoUrl];
      } else if (photos.isEmpty && p.avatarUrl.isNotEmpty) {
        photos = [p.avatarUrl];
      }
      if (photos.isNotEmpty) _cards.add((profile: p, photos: photos));
    }
    if (_cards.isNotEmpty) {
      UserPrefs.saveDiscoverDeck([for (final c in _cards) c.profile.id]);
    }
  }

  /// Reload today's cached deck by profile id (bypasses the live feed filter
  /// so "Recommencer" still works after everyone was liked / matched).
  Future<bool> _hydrateCachedDeck() async {
    final ids = await UserPrefs.loadDiscoverDeckToday();
    if (ids.isEmpty || !isSupabaseReady) return false;
    try {
      final profiles = await ProfileApi.fetchByIds(ids);
      if (profiles.isEmpty) return false;
      final byId = {for (final p in profiles) p.id: p};
      final ordered = [
        for (final id in ids)
          if (byId[id] != null) byId[id]!,
      ];
      if (ordered.isEmpty) return false;
      if (!mounted) return false;
      setState(() {
        _profiles = ordered;
        _rebuildCards();
      });
      return _cards.isNotEmpty;
    } catch (e) {
      debugPrint('discover: hydrate cache failed: $e');
      return false;
    }
  }

  /// Replay today's deck from the first card — no network required.
  void _restartDeck() {
    if (_cards.isEmpty) return;
    setState(() {
      _deckDone = false;
      _currentIndex = 0;
      _infoOpen = false;
    });
    NavChrome.show();
    UserPrefs.clearDiscoverDone();
    UserPrefs.saveDiscoverCursor(_cards.first.profile.id);
    _precacheAround(0);
  }

  int _currentIndex = 0;
  /// True once every card has been swiped today — show the end-of-deck screen
  /// instead of looping back to the first profile.
  bool _deckDone = false;
  final _stackKey = GlobalKey<_TinderCardStackState>();
  List<Friendship> _myFriendships = const [];

  bool get _hasActiveCard =>
      !_feedLoading && _cards.isNotEmpty && !_deckDone;

  // Search
  bool _searchExpanded = false;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _searchDebounce;
  Timer? _pollTimer;
  String _myId = '';
  bool _searching = false;
  List<RemoteProfile> _searchResults = const [];

  /// The card's info panel: pulled up from the photo, folded back down by a
  /// drag or a tap on the scrim. While it's open the nav bar slides away and
  /// the ✕ / ♥ float on top of the card.
  bool _infoOpen = false;

  void _openInfo() {
    if (_infoOpen || !_hasActiveCard) return;
    setState(() => _infoOpen = true);
    NavChrome.hide();
  }

  void _closeInfo() {
    if (!_infoOpen) return;
    setState(() => _infoOpen = false);
    NavChrome.show();
  }

  // Tabs
  int _activeTab = 0;
  static const _tabs = ['Pour vous', 'Double Date', 'Astrologie'];

  @override
  void initState() {
    super.initState();
    Analytics.track('screen_view', props: {'screen': 'discover'});
    _bootstrap();
    _pollTimer = WebPoll.every(const Duration(seconds: 12), _refreshFriendships);
  }

  @override
  void dispose() {
    NavChrome.show();
    _pollTimer?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _refreshFriendships() async {
    if (_myId.isEmpty || !isSupabaseReady) return;
    try {
      final mine = await FriendshipApi.fetchMine(_myId);
      if (mounted) setState(() => _myFriendships = mine);
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    if (!isSupabaseReady || id.isEmpty) {
      setState(() => _feedLoading = false);
      AppBoot.markHomeReady();
      return;
    }
    try {
      final results = await Future.wait(<Future<Object>>[
        FriendshipApi.fetchMine(id),
        ProfileApi.fetchDiscoverFeed(myId: id),
        UserPrefs.loadDiscoverCursor(),
        UserPrefs.loadDiscoverDoneToday(),
      ]).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      final friendships = results[0] as List<Friendship>;
      var feed = results[1] as List<RemoteProfile>;
      final cursor = results[2] as String;
      final doneToday = results[3] as bool;

      setState(() {
        _myFriendships = friendships;
        _profiles = feed;
        _rebuildCards();
      });

      // Live feed empty (everyone already liked) but we still have today's
      // deck cached → restore it so Restart / end-of-day can replay.
      if (_cards.isEmpty) {
        final ok = await _hydrateCachedDeck();
        debugPrint('discover: feed empty, cache hydrate=$ok');
      }

      if (!mounted) return;
      setState(() {
        if (_cards.isNotEmpty) {
          if (doneToday) {
            _deckDone = true;
            _currentIndex = _cards.length;
          } else if (cursor.isNotEmpty) {
            final idx = _cards.indexWhere((c) => c.profile.id == cursor);
            if (idx >= 0) _currentIndex = idx;
          }
        }
        _feedLoading = false;
      });
      debugPrint(
        'discover: feed=${feed.length} cards=${_cards.length} '
        'done=$_deckDone idx=$_currentIndex',
      );
      AppBoot.markHomeReady();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_deckDone) _precacheAround(_currentIndex);
      });
    } catch (e) {
      debugPrint('discover: bootstrap failed: $e');
      // Last resort: show today's cached deck if the network timed out.
      final ok = await _hydrateCachedDeck();
      if (mounted) {
        setState(() {
          if (ok && _cards.isNotEmpty) {
            // Keep them on the end screen only if they already finished today.
            // loadDiscoverDoneToday is async — best-effort false here; Restart works either way.
            _currentIndex = 0;
          }
          _feedLoading = false;
        });
      }
      AppBoot.markHomeReady();
    }
  }

  void _precacheAround(int index) {
    if (!mounted || _cards.isEmpty || _deckDone) return;
    final n = _cards.length;
    final seen = <String>{};
    for (var off = 0; off <= 5; off++) {
      final i = index + off;
      if (i < 0 || i >= n) continue;
      for (final url in _cards[i].photos) {
        if (url.isNotEmpty && seen.add(url)) {
          precacheImage(NetworkImage(url), context).ignore();
        }
      }
    }
  }

  /// Swipe left = a like (see the inversion note on [_onCardSwiped]). If the
  /// peer had already liked me the likes meet and it's a match right away —
  /// celebrate it over the card stack.
  Future<void> _likePeer(RemoteProfile peer) async {
    final res = await FriendshipApi.like(meId: _myId, peerId: peer.id);
    Analytics.track(
      'friend_request_sent',
      props: {'source': 'discover', 'kind': res.matched ? 'match' : 'like'},
    );
    if (!mounted) return;
    final f = res.friendship;
    if (f != null) {
      setState(() => _myFriendships = [..._myFriendships, f]);
    }
    if (res.matched) await _celebrateMatch(peer);
  }

  /// "It's a match!" over the Discover stack. "Dis bonjour" opens the DM.
  Future<void> _celebrateMatch(RemoteProfile peer) async {
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
          MaterialPageRoute<void>(
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

  FriendshipStatus _statusFor(RemoteProfile peer) =>
      FriendshipApi.statusWith(_myId, peer.id, _myFriendships).$1;

  void _onCardSwiped(bool isRight, RemoteProfile profile) {
    _closeInfo();
    // Inverted on request: dragging/flying LEFT is now the like, RIGHT the
    // refuse — the opposite of the original Tinder convention. Kept as a
    // single flip here rather than renaming `isRight` everywhere upstream.
    if (!isRight) {
      HapticFeedback.lightImpact();
      _likePeer(profile);
    }
    if (!mounted || _cards.isEmpty) return;
    final next = _currentIndex + 1;
    if (next >= _cards.length) {
      setState(() {
        _currentIndex = _cards.length;
        _deckDone = true;
      });
      UserPrefs.markDiscoverDoneToday();
      UserPrefs.saveDiscoverCursor('');
      return;
    }
    setState(() {
      _currentIndex = next;
      _deckDone = false;
      UserPrefs.saveDiscoverCursor(_cards[_currentIndex].profile.id);
      _precacheAround(_currentIndex);
    });
  }

  void _onActionUndo() {
    if (_cards.isEmpty) return;
    if (_deckDone) {
      _restartDeck();
      return;
    }
    if (_currentIndex <= 0) return;
    setState(() {
      _currentIndex -= 1;
      UserPrefs.saveDiscoverCursor(_cards[_currentIndex].profile.id);
      _precacheAround(_currentIndex);
    });
  }

  void _onSwipeLeft() => _stackKey.currentState?.triggerSwipe(false);
  void _onSwipeRight() => _stackKey.currentState?.triggerSwipe(true);

  // Search
  void _openSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchFocus.unfocus();
    setState(() {
      _searchExpanded = false;
      _searchCtrl.clear();
      _searchResults = const [];
      _searching = false;
    });
  }

  void _onSearchChanged(String v) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () => _runSearch(v));
  }

  Future<void> _runSearch(String value) async {
    final q = value.trim();
    if (q.isEmpty) {
      if (mounted) setState(() { _searchResults = const []; _searching = false; });
      return;
    }
    if (!isSupabaseReady || _myId.isEmpty) return;
    setState(() => _searching = true);
    try {
      final r = await ProfileApi.searchProfiles(query: q, myDeviceId: _myId);
      if (mounted) setState(() => _searchResults = r);
    } catch (_) {
      if (mounted) setState(() => _searchResults = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openResult(RemoteProfile peer) async {
    _closeSearch();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: peer.id)),
    );
    if (mounted) _refreshFriendships();
  }

  /// Empty-state / end-of-deck Restart.
  /// Prefer replaying the cards we already have (or today's cache). A live
  /// refetch alone often returns [] once everyone is liked — that's why the
  /// button looked broken.
  Future<void> _reset() async {
    if (_cards.isNotEmpty) {
      _restartDeck();
      return;
    }
    if (_myId.isEmpty) return;
    setState(() {
      _feedLoading = true;
      _currentIndex = 0;
      _deckDone = false;
    });
    await UserPrefs.clearDiscoverDone();
    await UserPrefs.saveDiscoverCursor('');
    try {
      final feed = await ProfileApi.fetchDiscoverFeed(myId: _myId);
      if (!mounted) return;
      setState(() {
        _profiles = feed;
        _rebuildCards();
      });
      if (_cards.isEmpty) {
        final ok = await _hydrateCachedDeck();
        debugPrint('discover: reset feed=${feed.length} cache=$ok');
      }
      if (!mounted) return;
      setState(() {
        _currentIndex = 0;
        _deckDone = false;
        _feedLoading = false;
      });
      if (_cards.isNotEmpty) {
        UserPrefs.saveDiscoverCursor(_cards.first.profile.id);
        _precacheAround(0);
      }
    } catch (e) {
      debugPrint('discover: reset failed: $e');
      final ok = await _hydrateCachedDeck();
      if (!mounted) return;
      setState(() {
        _currentIndex = 0;
        _deckDone = false;
        _feedLoading = false;
      });
      if (ok && _cards.isNotEmpty) {
        UserPrefs.saveDiscoverCursor(_cards.first.profile.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    // 58 (bouton) + 2 × 9 (respiration) : la bande blanche serre les boutons
    // au lieu de leur faire un socle.
    const actionH = 76.0;
    // Écart entre le bas de la bande blanche et la nav. Tout le reste en
    // découle : `cardBottom` se calcule à partir de `btnBottom`, donc monter
    // cette valeur remonte la bande ET raccourcit la photo d'autant. C'est la
    // seule ligne à toucher pour régler la respiration au-dessus de la nav.
    const gapToNav = 32.0;
    final btnBottom = GlassNavBar.totalReservedHeight + safeBottom + gapToNav;
    // La photo s'arrête PILE sur la bande — mais avec des coins bas arrondis,
    // donc le blanc doit aussi passer DERRIÈRE elle (voir le socle plus bas),
    // sinon les arrondis s'ouvriraient sur le fond noir de la page.
    final cardBottom = btnBottom + actionH;
    final tabBarH = safeTop + _TopTabBar.height;

    // Panneau ouvert : la carte prend toute la hauteur — elle monte sous la
    // barre d'onglets et descend dans l'espace libéré par la nav. Le panneau y
    // gagne assez de place pour tout montrer sans qu'on ait à faire défiler.
    final openCardBottom = safeBottom + 12;
    final currentCardBottom = _infoOpen ? openCardBottom : cardBottom;
    final currentCardTop = _infoOpen ? safeTop + 4 : tabBarH + 8;

    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: Stack(
        children: [
          // ── Card — flotte sous le header (coins arrondis bien visibles) ──
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            top: currentCardTop,
            left: _kCardInset,
            right: _kCardInset,
            bottom: currentCardBottom,
            child: _feedLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : _cards.isEmpty
                    ? _Empty(onReset: _reset)
                    : _deckDone
                        ? _DiscoverDone(onRestart: _restartDeck)
                        : _TinderCardStack(
                            key: _stackKey,
                            cards: _cards,
                            currentIndex: _currentIndex,
                            onSwiped: _onCardSwiped,
                            onPullUp: _openInfo,
                            infoOpen: _infoOpen,
                            onCloseInfo: _closeInfo,
                          ),
          ),

          // ── Retour arrière — coin haut-GAUCHE de la photo, verre nu (pas de
          //    liseré cyan : seule l'icône est colorée). ─────────────────────
          if (_hasActiveCard && !_infoOpen)
            Positioned(
              top: tabBarH + 20,
              // Même retrait DANS la carte qu'avant : il suit sa marge.
              left: _kCardInset + 12,
              child: _CardUndoButton(onTap: _onActionUndo),
            ),

          // ── Top bar — flotte sur la card ──────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopTabBar(
              tabs: _tabs,
              activeIndex: _activeTab,
              onTabSelected: (i) => setState(() => _activeTab = i),
              onSearch: _openSearch,
              onSettings: () {},
              topInset: safeTop,
              searchExpanded: _searchExpanded,
              searchController: _searchCtrl,
              searchFocus: _searchFocus,
              onSearchChanged: _onSearchChanged,
              onCloseSearch: _closeSearch,
            ),
          ),

          // ── Bas blanc + boutons — sous la carte au repos, flottant
          //    PAR-DESSUS elle (sur le panneau) dès qu'il est déplié.
          //    Au repos, le blanc remonte d'un rayon DERRIÈRE la photo pour en
          //    combler les deux coins arrondis : les deux surfaces n'en font
          //    qu'une. Déplié, ce raccord n'a plus rien à épouser — il tombe à
          //    zéro, sinon deux cornes blanches dépasseraient sur le panneau.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: _infoOpen ? safeBottom + 4 : btnBottom,
            height: actionH + (_infoOpen ? 0 : _kCardRadius),
            child: _hasActiveCard
                ? _SwipeActionBar(
                    height: actionH,
                    topJoin: _infoOpen ? 0 : _kCardRadius,
                    // Buttons keep their usual left/right position; only which
                    // physical fly-off they trigger is swapped, to match the
                    // inverted drag semantics (left = like, right = refuse).
                    onNope: _onSwipeRight,
                    onLike: _onSwipeLeft,
                    onMessage: () {
                      if (!_hasActiveCard) return;
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => ProfileScreen(
                            userId: _cards[_currentIndex].profile.id,
                          ),
                        ),
                      );
                    },
                  )
                : const SizedBox.shrink(),
          ),

          // ── Search overlay ────────────────────────────────────────────────
          if (_searchExpanded) ...[
            Positioned.fill(
              top: tabBarH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSearch,
                child: const ColoredBox(color: Color(0x88000000)),
              ),
            ),
            if (_searchCtrl.text.trim().isNotEmpty)
              Positioned(
                left: 12,
                right: 12,
                top: tabBarH + 8,
                child: _SearchOverlay(
                  loading: _searching,
                  results: _searchResults,
                  query: _searchCtrl.text.trim(),
                  statusFor: _statusFor,
                  onAdd: _likePeer,
                  onOpen: _openResult,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MyCardPreviewScreen — ma carte Discover, telle que les autres la voient
// ══════════════════════════════════════════════════════════════════════════════

/// L'œil du profil ouvre ceci : MA carte, rendue avec exactement le même widget
/// que le feed ([_TinderCard] + [_ProfileInfoPanel]), donc avec mes photos, mon
/// nom, mon drapeau, ma ville et — panneau déplié — ma bio, mes infos et mes
/// centres d'intérêt. Pas de swipe, pas de X / cœur : on ne se matche pas
/// soi-même.
class MyCardPreviewScreen extends StatefulWidget {
  const MyCardPreviewScreen({super.key});

  @override
  State<MyCardPreviewScreen> createState() => _MyCardPreviewScreenState();
}

class _MyCardPreviewScreenState extends State<MyCardPreviewScreen> {
  RemoteProfile? _me;
  bool _loading = true;
  bool _infoOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await DeviceId.getOrCreate();
    final me = isSupabaseReady ? await ProfileApi.fetchById(id) : null;
    if (!mounted) return;
    setState(() {
      _me = me;
      _loading = false;
    });
  }

  /// Même repli que le feed : la galerie d'abord, sinon la photo Discover,
  /// sinon la PDP. Une liste vide reste possible (aucune photo encore) — la
  /// carte se rend alors sur son fond sombre, ce qui EST ce que les autres
  /// verraient.
  List<String> get _photos {
    final p = _me;
    if (p == null) return const [];
    final gallery = p.photos.where((u) => u.isNotEmpty).toList();
    if (gallery.isNotEmpty) return gallery;
    if (p.discoverPhotoUrl.isNotEmpty) return [p.discoverPhotoUrl];
    if (p.avatarUrl.isNotEmpty) return [p.avatarUrl];
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final me = _me;

    return Scaffold(
      backgroundColor: SC.bg,
      body: Stack(
        children: [
          Positioned(
            top: safeTop + 64,
            left: 8,
            right: 8,
            bottom: safeBottom + 12,
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : me == null
                    ? Center(
                        child: Text(
                          AppStrings.t('info_empty'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 14,
                          ),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, c) {
                          final panelH = c.maxHeight * 0.76;
                          final card = _TinderCard(
                            profile: me,
                            photos: _photos,
                          );
                          final country =
                              flagCountryForLanguage(me.language);
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: country != null
                                    ? FlagBorder(
                                        country: country,
                                        radius: 24,
                                        child: card,
                                      )
                                    : ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(24),
                                        child: card,
                                      ),
                              ),
                              // Tirer la photo vers le haut déplie le panneau,
                              // exactement comme dans le feed.
                              if (!_infoOpen)
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onVerticalDragEnd: (d) {
                                      if ((d.primaryVelocity ?? 0) < -120) {
                                        setState(() => _infoOpen = true);
                                      }
                                    },
                                  ),
                                ),
                              // Et une fois déplié, la photo restée visible
                              // referme — au tap comme au glissement vers le
                              // bas, comme dans le feed.
                              if (_infoOpen)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 0,
                                  bottom: panelH,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () =>
                                        setState(() => _infoOpen = false),
                                    onVerticalDragEnd: (d) {
                                      if ((d.primaryVelocity ?? 0) > 0) {
                                        setState(() => _infoOpen = false);
                                      }
                                    },
                                  ),
                                ),
                              AnimatedPositioned(
                                duration: const Duration(milliseconds: 280),
                                curve: Curves.easeOutCubic,
                                left: 0,
                                right: 0,
                                height: panelH,
                                bottom: _infoOpen ? 0 : -panelH,
                                child: _ProfileInfoPanel(
                                  profile: me,
                                  onClose: () =>
                                      setState(() => _infoOpen = false),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
          ),
          // Retour + bandeau "voici ta carte telle que les autres la voient".
          Positioned(
            top: safeTop + 8,
            left: 16,
            right: 16,
            child: Row(
              children: [
                GlassIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppStrings.t('profile_preview_banner'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.70),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Top Tinder-style tab bar (frosted glass dark)
// ══════════════════════════════════════════════════════════════════════════════

class _TopTabBar extends StatelessWidget {
  const _TopTabBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTabSelected,
    required this.onSearch,
    required this.onSettings,
    required this.searchExpanded,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onCloseSearch,
    this.topInset = 0,
  });

  final List<String> tabs;
  final int activeIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final double topInset;

  /// Search: the loupe stretches open into the field right here in the header
  /// (220 ms), the wordmark stepping aside while it does.
  final bool searchExpanded;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onCloseSearch;

  // Content height (excluding safe-area top inset)
  static const double height = 52.0;

  @override
  Widget build(BuildContext context) {
    // No blur — readability comes from the card's top gradient behind it.
    return Container(
      height: height + topInset,
      padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
      child: Row(
            children: [
              // Wordmark swaycø — le "ø" en cyan. Il s'efface pendant la
              // recherche pour laisser le champ s'étirer sur toute la barre.
              if (!searchExpanded)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSettings,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: 'swayc'),
                        TextSpan(
                          text: 'ø',
                          style: TextStyle(color: Color(0xFF22D3EE)),
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
                ),
              ),
              // Onglets retirés — logo à gauche, actions à droite.
              const Spacer(),
              // La loupe s'ouvre EN champ : même pastille, largeur animée
              // (220 ms) — le geste d'origine, avant que la recherche ne
              // s'ouvre d'un coup.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: searchExpanded ? null : onSearch,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  width: searchExpanded
                      ? (MediaQuery.sizeOf(context).width - 56).clamp(
                          200.0,
                          520.0,
                        )
                      : 40,
                  height: 40,
                  padding: EdgeInsets.symmetric(
                    horizontal: searchExpanded ? 14 : 8,
                  ),
                  decoration: BoxDecoration(
                    color: searchExpanded
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: searchExpanded
                          ? Colors.white.withValues(alpha: 0.18)
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.search_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                      if (searchExpanded) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: searchController,
                            focusNode: searchFocus,
                            onChanged: onSearchChanged,
                            textInputAction: TextInputAction.search,
                            cursorColor: const Color(0xFF22D3EE),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: AppStrings.t('search_friend_hint'),
                              hintStyle: const TextStyle(
                                color: Colors.white54,
                                fontSize: 15,
                              ),
                              // The pill already draws the surface. Without
                              // these the theme paints its navy fill and cyan
                              // focus ring INSIDE the pill — a square box on
                              // top of a rounded one.
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 8,
                              ),
                            ),
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onCloseSearch,
                          child: const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Tinder card stack (3 layered cards)
// ══════════════════════════════════════════════════════════════════════════════

class _TinderCardStack extends StatefulWidget {
  const _TinderCardStack({
    super.key,
    required this.cards,
    required this.currentIndex,
    required this.onSwiped,
    required this.onPullUp,
    required this.infoOpen,
    required this.onCloseInfo,
  });

  final List<({RemoteProfile profile, List<String> photos})> cards;
  final int currentIndex;
  final void Function(bool isRight, RemoteProfile profile) onSwiped;

  /// Dragging the photo upward asks for the info panel.
  final VoidCallback onPullUp;

  /// True while that panel is up — it covers the bottom half of the card.
  final bool infoOpen;
  final VoidCallback onCloseInfo;

  @override
  State<_TinderCardStack> createState() => _TinderCardStackState();
}

class _TinderCardStackState extends State<_TinderCardStack> {
  GlobalKey<_DraggableCardState> _topKey = GlobalKey<_DraggableCardState>();
  final _progress = ValueNotifier<double>(0.0);

  /// Ce qu'on a déjà demandé au réseau — inutile de redemander à chaque
  /// reconstruction, le cache d'images de Flutter garde la suite.
  final Set<String> _warmed = {};

  @override
  void initState() {
    super.initState();
    _warmNext();
  }

  @override
  void didUpdateWidget(_TinderCardStack old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      _topKey = GlobalKey<_DraggableCardState>();
      _progress.value = 0.0;
      _warmNext();
    }
  }

  /// Télécharge À L'AVANCE la photo des deux cartes suivantes.
  ///
  /// Une carte ne demandait son image qu'au moment de s'afficher : on balayait,
  /// et on regardait un rectangle vide pendant que le réseau répondait. Ici la
  /// photo d'après est déjà dans le cache quand la carte arrive — le balayage
  /// ne montre plus d'attente. Deux cartes d'avance suffisent : au-delà on
  /// télécharge des visages que la personne ne verra peut-être jamais.
  void _warmNext() {
    final n = widget.cards.length;
    if (n == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (var step = 1; step <= 2; step++) {
        final i = widget.currentIndex + step;
        if (i >= n) break;
        final card = widget.cards[i];
        final url = card.photos.isEmpty ? '' : card.photos.first;
        if (url.isEmpty || !_warmed.add(url)) continue;
        precacheImage(NetworkImage(url), context).catchError((_) {
          // Une photo qui ne se charge pas ici se rechargera (ou échouera)
          // à l'affichage, où l'erreur est déjà gérée.
        });
      }
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void triggerSwipe(bool isRight) => _topKey.currentState?.programmaticSwipe(isRight);

  @override
  Widget build(BuildContext context) {
    final n = widget.cards.length;
    if (n == 0) return const SizedBox.shrink();
    final i = widget.currentIndex.clamp(0, n - 1);
    final hasMid = i + 1 < n;
    final hasBack = i + 2 < n;

    return LayoutBuilder(
      builder: (context, c) {
        // Le panneau prend les trois quarts de la carte : assez pour poser la
        // bio, les faits et les intérêts d'un coup. La bande de photo qui
        // reste au-dessus sert de poignée pour le rabattre.
        final panelH = c.maxHeight * 0.76;
        return Stack(
        children: [
          // Back card (3rd)
          if (hasBack)
            _StackCard(
              key: ValueKey('back_${i + 2}'),
              scale: 0.90,
              translateY: 18,
              child: _buildCard(widget.cards[i + 2]),
            ),
          // Middle card (2nd) — scales up as top card moves
          if (hasMid)
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (_, p, child) => _StackCard(
                key: ValueKey('mid_${i + 1}'),
                scale: 0.95 + 0.05 * p.clamp(0.0, 1.0),
                translateY: 9 * (1 - p.clamp(0.0, 1.0)),
                child: _buildCard(widget.cards[i + 1]),
              ),
            ),
          // Top card (interactive)
          KeyedSubtree(
            key: ValueKey('top_$i'),
            child: _DraggableCard(
              key: _topKey,
              onSwiped: (right) => widget.onSwiped(right, widget.cards[i].profile),
              onProgress: (p) => _progress.value = p,
              // Pulling the photo up is what opens the panel — no chevron.
              onPullUp: widget.onPullUp,
              locked: widget.infoOpen,
              child: _buildCard(widget.cards[i]),
            ),
          ),
          // Au-dessus du panneau : la bande de photo qui reste sert à
          // REFERMER. Un tap y rabat le panneau — c'est le geste que tout le
          // monde tente en premier — et un glissement vers le bas aussi. Le
          // carrousel de photos y perd ses taps gauche/droite tant que le
          // panneau est ouvert : sortir d'abord, feuilleter ensuite.
          if (widget.infoOpen)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: panelH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onCloseInfo,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 0) widget.onCloseInfo();
                },
              ),
            ),
          // The panel itself — slides up from the bottom edge of the card.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            height: panelH,
            bottom: widget.infoOpen ? 0 : -panelH,
            child: _ProfileInfoPanel(
              profile: widget.cards[i].profile,
              onClose: widget.onCloseInfo,
            ),
          ),
        ],
      );
      },
    );
  }

  Widget _buildCard(({RemoteProfile profile, List<String> photos}) card) {
    // Carte photo arrondie qui flotte sur le fond noir de la page, cerclée
    // d'un liseré aux couleurs du drapeau de la langue parlée par le profil.
    final tinderCard = _TinderCard(
      key: ValueKey(card.profile.id),
      profile: card.profile,
      photos: card.photos,
    );
    final country = flagCountryForLanguage(card.profile.language);
    // Arrondie sur ses QUATRE coins : elle est posée sur la bande blanche, pas
    // soudée à elle — le blanc qu'on voit dans les deux arrondis du bas vient
    // du socle glissé derrière.
    return SizedBox.expand(
      child: country != null
          ? FlagBorder(
              country: country,
              radius: _kCardRadius,
              borderWidth: 3,
              child: tinderCard,
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(_kCardRadius),
              child: tinderCard,
            ),
    );
  }
}

/// Le panneau que la carte déplie : la bio d'abord, puis les infos que la
/// personne a choisi de partager (âge, taille, métier, signe, ce qu'elle
/// cherche), puis ses centres d'intérêt. Il reste DANS la carte — on ne change
/// pas de page — et se rabat d'un glissement vers le bas.
class _ProfileInfoPanel extends StatefulWidget {
  const _ProfileInfoPanel({required this.profile, required this.onClose});

  final RemoteProfile profile;
  final VoidCallback onClose;

  @override
  State<_ProfileInfoPanel> createState() => _ProfileInfoPanelState();
}

class _ProfileInfoPanelState extends State<_ProfileInfoPanel> {
  /// Distance parcourue vers le bas depuis le début du geste. Fermer sur le
  /// seul élan demandait un coup sec : un glissement lent, celui qu'on fait
  /// quand on croit scroller, mourait à zéro de vélocité et le panneau
  /// restait planté là.
  double _dragDy = 0;

  /// Vrai depuis l'instant où le débord a demandé la fermeture jusqu'au retour
  /// de la liste à sa position haute : sans lui, chaque image du geste
  /// rappellerait onClose.
  bool _dismissing = false;

  /// Le débord vers le haut vaut fermeture. [ScrollUpdateNotification] porte
  /// des pixels négatifs quand la liste est tirée sous son point de départ —
  /// c'est là, et seulement là, que le glissement cesse d'être du défilement.
  bool _onPanelScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final over = n.metrics.pixels;
      if (over >= 0) {
        _dismissing = false;
      } else if (!_dismissing && over < -70) {
        _dismissing = true;
        widget.onClose();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final place = [p.city.trim(), p.country.trim()]
        .where((e) => e.isNotEmpty)
        .join(', ');
    // Toujours les cinq pastilles, remplies ou non : un champ vide qui fait
    // disparaître sa ligne (emoji compris) rendait le panneau à trous —
    // vide de tout sauf le prénom, on aurait dit une carte cassée plutôt
    // qu'un profil juste peu rempli. La pastille reste, seul son contenu
    // change.
    final facts = <({String emoji, String label, bool filled})>[
      (
        emoji: kFactEmojiAge,
        label: p.age != null
            ? AppStrings.t('info_age_value', args: {'n': '${p.age}'})
            : '—',
        filled: p.age != null,
      ),
      (
        emoji: kFactEmojiJob,
        label: p.job.trim().isNotEmpty ? displayJob(p.job) : '—',
        filled: p.job.trim().isNotEmpty,
      ),
      (
        emoji: kFactEmojiZodiac,
        label: p.zodiac.trim().isNotEmpty ? displayZodiac(p.zodiac) : '—',
        filled: p.zodiac.trim().isNotEmpty,
      ),
      (
        emoji: kFactEmojiLookingFor,
        label:
            p.lookingFor.trim().isNotEmpty ? displayLookingFor(p.lookingFor) : '—',
        filled: p.lookingFor.trim().isNotEmpty,
      ),
      (
        emoji: kFactEmojiPlace,
        label: place.isNotEmpty ? place : '—',
        filled: place.isNotEmpty,
      ),
      // Pas de ligne "langue" : le drapeau est déjà sur la photo, et l'app
      // traduit — savoir ce que l'autre parle ne change rien.
    ];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Un glissement vers le bas suffit à le rabattre — pas de bouton. Un
      // coup sec OU 56 px parcourus : les deux ferment.
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 120 || _dragDy > 56) widget.onClose();
      },
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: DecoratedBox(
          // Fond OPAQUE, plus de verre : le flou laissait passer la photo, et
          // une photo n'est jamais assez uniforme pour porter du texte — selon
          // le cliché, un mot sur deux tombait sur une zone claire. Le panneau
          // est maintenant une page à lui, posée devant l'image.
          decoration: const BoxDecoration(
            color: _kPanelBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // La poignée : elle dit "tire-moi vers le bas".
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 8),
                  child: Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  // Le contenu défile. Et comme un défilement s'approprie tout
                  // glissement vertical, c'est LUI qui porte la fermeture :
                  // tiré vers le bas alors qu'on est déjà en haut de la liste,
                  // le geste n'est plus du défilement, c'est un « referme-moi »
                  // (70 px de débord suffisent). D'où la physique élastique,
                  // AlwaysScrollable pour qu'un profil court se tire aussi.
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onPanelScroll,
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 96),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      // Le prénom EN TÊTE du panneau : déplié, il recouvre
                      // celui posé sur la photo, et on ne sait plus de qui on
                      // lit la fiche. L'âge le suit, et la paire de langues
                      // ferme la ligne — c'est la promesse de l'app, elle vaut
                      // d'être dite avant la bio.
                      _PanelHeader(profile: p),
                      const SizedBox(height: 20),
                      if (p.bio.trim().isNotEmpty) ...[
                        _PanelSectionTitle(AppStrings.t('info_bio')),
                        const SizedBox(height: 8),
                        TranslatedProfileText(
                          text: p.bio.trim(),
                          profileId: p.id,
                          field: 'bio',
                          fromLang: p.language,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontSize: 15.5,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 22),
                      ],
                      // Inconditionnel désormais : `facts` porte toujours ses
                      // cinq pastilles (remplies ou en tiret), donc cette
                      // section n'est plus jamais vide.
                      _PanelSectionTitle(AppStrings.t('info_about')),
                      const SizedBox(height: 10),
                      // Deux colonnes : en une seule, six lignes d'une ligne
                      // chacune faisaient une liste à trous — la moitié de la
                      // largeur restait vide et le panneau descendait pour
                      // rien.
                      LayoutBuilder(
                        builder: (ctx, c) {
                          final w = (c.maxWidth - 10) / 2;
                          return Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final f in facts)
                                SizedBox(
                                  width: w,
                                  child: _FactChip(
                                    emoji: f.emoji,
                                    label: f.label,
                                    filled: f.filled,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 22),
                      if (p.interests.isNotEmpty) ...[
                        _PanelSectionTitle(AppStrings.t('info_interests')),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final tag in p.interests)
                              InterestTagChip(
                                label: tag,
                                color: interestColor(tag),
                              ),
                          ],
                        ),
                      ],
                      ],
                      ),
                    ),
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

class _PanelSectionTitle extends StatelessWidget {
  const _PanelSectionTitle(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.45),
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    );
  }
}

/// La première ligne du panneau : prénom + drapeau (l'âge est dans « À propos »).
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.profile});

  final RemoteProfile profile;

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.trim().isEmpty
        ? AppStrings.t('profile_anonymous')
        : profile.displayName.trim();
    final flag = (profile.city.trim().isNotEmpty
            ? countryFlagFor(profile.country)
            : null) ??
        findLanguageByCode(profile.language)?.flag ??
        '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
              height: 1.1,
            ),
          ),
        ),
        if (flag.isNotEmpty) ...[
          const SizedBox(width: 9),
          Text(flag, style: const TextStyle(fontSize: 26)),
        ],
      ],
    );
  }
}

/// Une info du bloc « À propos » : son emoji, puis sa valeur. Une pastille par
/// fait, deux par ligne. [filled] false = le champ n'est pas renseigné —
/// l'emoji reste, seule la valeur passe en tiret muet plutôt que de faire
/// disparaître toute la pastille.
class _FactChip extends StatelessWidget {
  const _FactChip({
    required this.emoji,
    required this.label,
    this.filled = true,
  });

  final String emoji;
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: filled ? 1 : 0.4,
            child: Text(emoji, style: const TextStyle(fontSize: 15)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: filled ? 0.92 : 0.4),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontStyle: filled ? FontStyle.normal : FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StackCard extends StatelessWidget {
  const _StackCard({
    super.key,
    required this.scale,
    required this.translateY,
    required this.child,
  });
  final double scale;
  final double translateY;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Transform.translate(
        offset: Offset(0, translateY),
        child: Transform.scale(scale: scale, child: child),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Draggable card — gesture, spring-back, fly-off
// ══════════════════════════════════════════════════════════════════════════════

const double _kThreshold = 90.0;



class _DraggableCard extends StatefulWidget {
  const _DraggableCard({
    super.key,
    required this.child,
    required this.onSwiped,
    required this.onProgress,
    this.onPullUp,
    this.locked = false,
  });
  final Widget child;
  final ValueChanged<bool> onSwiped;
  final ValueChanged<double> onProgress;

  /// Fired when the gesture was a real upward pull — the info panel opens
  /// instead of the card flying off.
  final VoidCallback? onPullUp;

  /// True while the panel is up: the card must not swipe under it.
  final bool locked;

  @override
  State<_DraggableCard> createState() => _DraggableCardState();
}

class _DraggableCardState extends State<_DraggableCard>
    with SingleTickerProviderStateMixin {
  Offset _pos = Offset.zero;
  bool _flying = false;
  int _gen = 0;

  late final AnimationController _ctrl = AnimationController(vsync: this)
    ..addListener(_tick);
  Animation<Offset>? _anim;

  void _tick() {
    final a = _anim;
    if (a == null) return;
    setState(() {
      _pos = a.value;
      widget.onProgress((_pos.dx.abs() / _kThreshold).clamp(0.0, 1.0));
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _animateTo(Offset target, Duration dur, Curve curve, {VoidCallback? done}) {
    final g = ++_gen;
    _anim = Tween<Offset>(begin: _pos, end: target)
        .animate(CurvedAnimation(parent: _ctrl, curve: curve));
    _ctrl
      ..duration = dur
      ..value = 0;
    _ctrl.forward().then((_) {
      if (mounted && _gen == g && _ctrl.status == AnimationStatus.completed) {
        done?.call();
      }
    });
  }

  void _springBack() {
    _animateTo(Offset.zero, const Duration(milliseconds: 500), Curves.elasticOut,
        done: () {
      if (mounted) {
        setState(() => _pos = Offset.zero);
        widget.onProgress(0);
      }
    });
  }

  void _flyOff(bool right) {
    _flying = true;
    _animateTo(
      Offset(right ? 1000.0 : -1000.0, _pos.dy),
      const Duration(milliseconds: 280),
      Curves.easeIn,
      done: () {
        if (mounted) widget.onSwiped(right);
      },
    );
  }

  void programmaticSwipe(bool right) {
    if (_flying) return;
    _flyOff(right);
  }

  // Position au pointer-down, pour savoir si le geste a vraiment dépassé le
  // seuil de drag. Tant que ce n'est pas le cas, on ne bouge pas la carte et
  // on laisse le tap (changement de photo) passer sans concurrence dans
  // l'arène de gestes — un simple GestureDetector(onPan...) "gagne" sur le
  // moindre micro-mouvement (souris web ~1px) et avale tous les taps.
  Offset? _dragOrigin;
  bool _dragEngaged = false;
  static const double _kDragEngageSlop = 6.0;

  /// Which way the finger committed once it passed the slop. An upward pull
  /// belongs to the info panel; anything else is the Tinder swipe. Deciding
  /// once, at engage time, keeps a sloppy diagonal from doing both.
  bool _pullingUp = false;
  static const double _kPullUpThreshold = 48.0;

  @override
  Widget build(BuildContext context) {
    final angle = (_pos.dx / 320.0) * 0.20;
    // Inverted on request: LIKE tracks the left drag, NOPE the right one.
    final likeOpacity = (-_pos.dx / 65.0).clamp(0.0, 1.0);
    final nopeOpacity = (_pos.dx / 65.0).clamp(0.0, 1.0);

    return Listener(
      onPointerDown: (e) {
        _dragOrigin = e.position;
        _dragEngaged = false;
      },
      onPointerMove: (e) {
        if (_flying || widget.locked) return;
        final origin = _dragOrigin;
        if (!_dragEngaged) {
          if (origin == null ||
              (e.position - origin).distance < _kDragEngageSlop) {
            return; // micro-mouvement : pas encore un drag, laisse le tap gagner
          }
          final d = e.position - origin;
          // Franchement vers le haut → c'est le panneau qu'on tire, pas la carte.
          _pullingUp = d.dy < 0 && d.dy.abs() > d.dx.abs();
          _dragEngaged = true;
          _ctrl.stop();
          _anim = null;
        }
        if (_pullingUp) {
          // On laisse la carte immobile : le panneau fera l'animation.
          _pos += Offset(0, e.delta.dy);
          return;
        }
        setState(() {
          _pos += Offset(e.delta.dx, e.delta.dy * 0.3);
          widget.onProgress((_pos.dx.abs() / _kThreshold).clamp(0.0, 1.0));
        });
      },
      onPointerUp: (_) {
        final wasEngaged = _dragEngaged;
        final wasPullingUp = _pullingUp;
        final travelled = _pos;
        _dragEngaged = false;
        _pullingUp = false;
        _dragOrigin = null;
        if (!wasEngaged || _flying) return;
        if (wasPullingUp) {
          _pos = Offset.zero;
          if (travelled.dy <= -_kPullUpThreshold) widget.onPullUp?.call();
          return;
        }
        if (_pos.dx.abs() >= _kThreshold) {
          _flyOff(_pos.dx > 0);
        } else {
          _springBack();
        }
      },
      onPointerCancel: (_) {
        _dragEngaged = false;
        _dragOrigin = null;
      },
      child: Transform.translate(
        offset: _pos,
        child: Transform.rotate(
          angle: angle,
          child: Stack(
            children: [
              widget.child,
              // LIKE à GAUCHE (le côté vers lequel on glisse pour matcher),
              // NOPE à droite — mouvement inversé sur demande.
              if (likeOpacity > 0.02)
                Positioned(
                  top: 36,
                  left: 24,
                  child: Opacity(
                    opacity: likeOpacity,
                    child: const _SwipeStamp(text: 'LIKE', color: Color(0xFF3DCA72)),
                  ),
                ),
              if (nopeOpacity > 0.02)
                Positioned(
                  top: 36,
                  right: 24,
                  child: Opacity(
                    opacity: nopeOpacity,
                    child: const _SwipeStamp(text: 'NOPE', color: Color(0xFFFF4458)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// LIKE / NOPE stamp
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeStamp extends StatelessWidget {
  const _SwipeStamp({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: text == 'LIKE' ? -0.26 : 0.26,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color, width: 3.5),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 32,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Tinder card — full-bleed photo carousel + info overlay
// ══════════════════════════════════════════════════════════════════════════════

class _TinderCard extends StatefulWidget {
  const _TinderCard({
    super.key,
    required this.profile,
    required this.photos,
  });
  final RemoteProfile profile;
  final List<String> photos;

  @override
  State<_TinderCard> createState() => _TinderCardState();
}

class _TinderCardState extends State<_TinderCard> {
  int _photoIndex = 0;

  void _nextPhoto() {
    if (_photoIndex < widget.photos.length - 1) {
      setState(() => _photoIndex++);
    }
  }

  void _prevPhoto() {
    if (_photoIndex > 0) setState(() => _photoIndex--);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final photos = widget.photos;
    final currentUrl = photos.isNotEmpty ? photos[_photoIndex] : '';

    final flag = (p.city.trim().isNotEmpty
            ? countryFlagFor(p.country)
            : null) ??
        findLanguageByCode(p.language)?.flag ??
        '';
    final location = [p.city.trim(), p.country.trim()]
        .where((s) => s.isNotEmpty)
        .join(', ');
    // La règle commune : elle ajoute ici la réciprocité qui manquait — masquer
    // son propre statut n'éteignait pas les pastilles des autres sur Discover.
    final online = isPeerOnline(p);
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Photo ──────────────────────────────────────────────────────────
        const ColoredBox(color: Color(0xFF111111)),
          if (currentUrl.isNotEmpty)
            Image.network(
              currentUrl,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.6),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),

          // ── Tap areas (photo carousel) ──────────────────────────────────
          if (photos.length > 1)
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _prevPhoto,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _nextPhoto,
                  ),
                ),
              ],
            ),

          // ── Photo dots — petits, centrés en haut ────────────────────────
          if (photos.length > 1)
            Positioned(
              // Descendues : collées au bord elles se perdaient dans l'encoche.
              top: 20,
              left: 0,
              right: 0,
              child: Center(
                child: _PhotoDots(count: photos.length, active: _photoIndex),
              ),
            ),

          // ── Bottom info + verre dépoli (épouse le contenu jusqu'en bas) ──
          // Verre dépoli décoratif au bas de la carte : il FOND en douceur
          // vers le haut (masque dégradé, pas de bord net) et reste concentré
          // Dégradé noir LISSE sur toute la carte (comme Tinder) — aucun
          // rectangle, aucun blur : transparent en haut, fondu progressif
          // jusqu'au noir en bas où reposent nom + boutons.
          // ── Bottom info (net, au-dessus des chevrons) ───────────────────
          Positioned(
            left: 14,
            // Plus de bouton dans le coin : le bloc peut aller au bord.
            right: 20,
            // Posé au-dessus des chevrons, qui sont tout en bas.
            bottom: 66,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name + flag + online dot
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        p.displayName.isEmpty ? '—' : p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.4,
                          shadows: [Shadow(color: Color(0x66000000), blurRadius: 10)],
                        ),
                      ),
                    ),
                    if (p.isPro) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.verified_rounded,
                          color: Color(0xFF60A5FA), size: 22),
                    ],
                    if (flag.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(flag, style: const TextStyle(fontSize: 22)),
                    ],
                    if (online) ...[
                      const SizedBox(width: 8),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4ADE80),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF4ADE80).withValues(alpha: 0.7),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                // Location
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_on, size: 13,
                          color: Colors.white.withValues(alpha: 0.70)),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // One chip on the card (the rest lives in the info panel):
                // the persona category ("what defines you most") when set —
                // the higher-signal, deliberate answer — else fall back to
                // the first interest tag for profiles onboarded before this
                // field existed.
                if (personaCategoryByLabel(p.personaCategory) != null) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      InterestTagChip(
                        label:
                            '${personaCategoryByLabel(p.personaCategory)!.emoji} '
                            '${personaCategoryLabel(p.personaCategory)}',
                        color: const Color(0xFF22D3EE),
                      ),
                    ],
                  ),
                ] else if (p.interests.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.apps_rounded, size: 13,
                          color: Colors.white.withValues(alpha: 0.65)),
                      const SizedBox(width: 5),
                      Text(
                        'Centres d\'intérêt',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.70),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          shadows: const [
                            Shadow(color: Color(0x55000000), blurRadius: 6),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final tag in p.interests.take(1))
                        InterestTagChip(
                          label: tag,
                          color: interestColor(tag),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // ── Repère "tire vers le haut" : les deux chevrons qui sautent,
          //    centrés tout en bas de la photo.
          const Positioned(
            left: 0,
            right: 0,
            bottom: 2,
            child: IgnorePointer(
              child: Center(child: _ScrollHintChevrons()),
            ),
          ),

        ],
      );
  }
}

/// Deux chevrons empilés qui SAUTENT vers le haut, puis retombent et
/// marquent une pause avant de recommencer. Le repère "il y a des infos à
/// découvrir, tire vers le haut", posé tout en bas de la carte.
///
/// (L'ancienne version faisait défiler les chevrons en boucle, façon
/// escalator ; le saut se lit mieux et n'attire pas l'œil en permanence.)
class _ScrollHintChevrons extends StatefulWidget {
  const _ScrollHintChevrons();

  @override
  State<_ScrollHintChevrons> createState() => _ScrollHintChevronsState();
}

class _ScrollHintChevronsState extends State<_ScrollHintChevrons>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Le chevron du bas part une fraction de seconde après celui du
          // haut : les deux sautent ensemble sans être collés.
          _chevron(0.0),
          Transform.translate(
            offset: const Offset(0, -14),
            child: _chevron(0.10),
          ),
        ],
      ),
    );
  }

  /// Un chevron, [delay] tours de retard sur le cycle. Le saut occupe la
  /// première moitié du cycle, le reste est une pause.
  Widget _chevron(double delay) {
    final u = (_c.value - delay) % 1.0;
    double lift;
    if (u < 0.25) {
      // Montée franche.
      lift = Curves.easeOutCubic.transform(u / 0.25);
    } else if (u < 0.5) {
      // Retombée.
      lift = 1 - Curves.easeInCubic.transform((u - 0.25) / 0.25);
    } else {
      lift = 0; // pause
    }
    return Transform.translate(
      offset: Offset(0, -12 * lift),
      child: Opacity(
        // À peine plus vif en haut du saut.
        opacity: 0.75 + 0.25 * lift,
        child: const Icon(
          Icons.keyboard_arrow_up_rounded,
          color: Colors.white,
          size: 34,
          shadows: [Shadow(color: Color(0x66000000), blurRadius: 8)],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Photo dots (Tinder-style thin lines)
// ══════════════════════════════════════════════════════════════════════════════

class _PhotoDots extends StatelessWidget {
  const _PhotoDots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            // Assez épais pour se voir sur une photo claire — c'est le seul
            // signe qu'il y a d'autres photos derrière — sans faire barre.
            width: 24,
            height: 4,
            decoration: BoxDecoration(
              color: i == active
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(3),
              boxShadow: const [
                BoxShadow(color: Color(0x66000000), blurRadius: 4),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Interest chip — dark pill (Tinder style)
// ══════════════════════════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════════════════════════
// Action bar — pass / like. The rewind arrow lives on the card now, and the
// super-like / send-a-message buttons are gone.
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeActionBar extends StatelessWidget {
  const _SwipeActionBar({
    required this.height,
    required this.topJoin,
    required this.onNope,
    required this.onLike,
    required this.onMessage,
  });

  /// Hauteur de la bande VISIBLE (celle qui porte les boutons).
  final double height;

  /// Hauteur du raccord qui remonte derrière la photo. Il ne déborde pas sur
  /// l'image : il n'en remplit que les deux coins arrondis, pour que le blanc
  /// et la carte se lisent d'un seul tenant. 0 = pas de raccord.
  final double topJoin;

  final VoidCallback onNope;
  final VoidCallback onLike;

  /// Kept wired (the profile opens from here) even though no button surfaces
  /// it any more — the card itself opens the profile.
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height + topJoin,
      child: Padding(
        // Même marge que la carte : les deux bords s'alignent au pixel.
        padding: const EdgeInsets.symmetric(horizontal: _kCardInset),
        child: CustomPaint(
          painter: _ActionBarShape(topJoin: topJoin, radius: _kCardRadius),
          child: Padding(
            // Les boutons se centrent dans la bande visible, jamais dans le
            // raccord — sinon ils descendraient d'un demi-rayon.
            padding: EdgeInsets.only(top: topJoin),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _ActionButton(
                  background: Colors.black,
                  onTap: onNope,
                  child: const Icon(Icons.close, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 45),
                _ActionButton(
                  background: const Color(0xFF22D3EE),
                  onTap: onLike,
                  child: const Icon(
                    Icons.favorite,
                    color: Color(0xFF111111),
                    size: 24,
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

/// Le bas blanc : une bande à bas arrondi, surmontée — quand [topJoin] > 0 —
/// des deux « cornes » qui viennent combler les coins arrondis du bas de la
/// photo. Ces cornes sont EXACTEMENT le complément de ces coins : le blanc
/// monte jusqu'au bord de l'image sans jamais mordre dessus, et la carte et la
/// bande n'ont plus de couture entre elles.
class _ActionBarShape extends CustomPainter {
  const _ActionBarShape({required this.topJoin, required this.radius});

  final double topJoin;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(radius);
    final bar = RRect.fromRectAndCorners(
      Rect.fromLTRB(0, topJoin, size.width, size.height),
      bottomLeft: r,
      bottomRight: r,
    );

    // Ombre du bloc (design swipe_card.dart : 0x59000000, blur 30, +12). Elle
    // ne part QUE de la bande : les cornes sont sous la photo, leur ombre
    // salirait le bas de l'image.
    canvas.drawPath(
      Path()..addRRect(bar.shift(const Offset(0, 12))),
      Paint()
        ..color = const Color(0x59000000)
        // sigma ≈ blurRadius × 0.57735, la conversion de BoxShadow.
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 17.3),
    );

    var shape = Path()..addRRect(bar);
    if (topJoin > 0) {
      // La bande du raccord MOINS l'empreinte du bas de la carte : il ne reste
      // que les deux angles que l'arrondi laissait ouverts sur le fond.
      final band = Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, topJoin));
      final cardFoot = Path()
        ..addRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(0, -radius, size.width, topJoin),
            bottomLeft: r,
            bottomRight: r,
          ),
        );
      shape = Path.combine(
        PathOperation.union,
        shape,
        Path.combine(PathOperation.difference, band, cardFoot),
      );
    }
    canvas.drawPath(shape, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ActionBarShape old) =>
      old.topJoin != topJoin || old.radius != radius;
}

/// Les deux boutons de match : un rond plein de 58, noir pour passer, cyan de
/// marque pour valider. Rien de translucide — ils sont posés sur du blanc.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.background,
    required this.child,
    this.onTap,
  });

  final Color background;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(width: 58, height: 58, child: Center(child: child)),
      ),
    );
  }
}

/// Le retour arrière posé sur la photo : verre flouté SANS contour coloré —
/// seule l'icône reste cyan, le cercle se fond dans l'image.
class _CardUndoButton extends StatelessWidget {
  const _CardUndoButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.replay_rounded,
              color: Color(0xFF22D3EE),
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}


// ══════════════════════════════════════════════════════════════════════════════
// Search overlay
// ══════════════════════════════════════════════════════════════════════════════

/// Le panneau de résultats, sous le header. Le champ de saisie, lui, vit dans
/// la barre du haut : c'est la loupe elle-même qui s'étire pour le devenir.
class _SearchOverlay extends StatelessWidget {
  const _SearchOverlay({
    required this.loading,
    required this.results,
    required this.query,
    required this.statusFor,
    required this.onAdd,
    required this.onOpen,
  });

  final bool loading;
  final List<RemoteProfile> results;
  final String query;
  final FriendshipStatus Function(RemoteProfile) statusFor;
  final ValueChanged<RemoteProfile> onAdd;
  final ValueChanged<RemoteProfile> onOpen;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [_buildResults()],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Aucun profil pour « $query »',
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: results.length,
        separatorBuilder: (_, _) =>
            Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
        itemBuilder: (_, i) {
          final peer = results[i];
          return _SearchRow(
            profile: peer,
            status: statusFor(peer),
            onTap: () => onOpen(peer),
            onAdd: () => onAdd(peer),
          );
        },
      ),
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.profile,
    required this.status,
    required this.onTap,
    required this.onAdd,
  });
  final RemoteProfile profile;
  final FriendshipStatus status;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            ProfileAvatar(
              displayName: profile.displayName,
              avatarUrl: profile.avatarUrl,
              size: 38,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    profile.displayName.isEmpty ? '—' : profile.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (profile.handle.isNotEmpty)
                    Text(
                      '@${profile.handle}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                ],
              ),
            ),
            _statusBadge(context),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(BuildContext context) {
    switch (status) {
      case FriendshipStatus.accepted:
        return _Pill(label: AppStrings.t('friendship_friend'), color: const Color(0xFF3DCA72));
      case FriendshipStatus.pendingOutgoing:
        return _Pill(label: AppStrings.t('friendship_sent'), color: Colors.amber);
      case FriendshipStatus.pendingIncoming:
        return _Pill(label: AppStrings.t('friendship_pending_in'), color: Colors.amber);
      case FriendshipStatus.rejected:
      case FriendshipStatus.none:
        return GestureDetector(
          onTap: onAdd,
          child: _Pill(label: AppStrings.t('add_friend_short'), color: const Color(0xFF3DCA72)),
        );
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.50)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Empty / end-of-deck
// ══════════════════════════════════════════════════════════════════════════════

/// Shown after the last Discover card — Restart replays from the first card.
class _DiscoverDone extends StatelessWidget {
  const _DiscoverDone({required this.onRestart});
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onRestart,
        borderRadius: BorderRadius.circular(28),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    color: SC.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: SC.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  child: const Icon(
                    Icons.replay_rounded,
                    color: SC.accent,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  AppStrings.t('discover_done'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  AppStrings.t('discover_done_back'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 22),
                TextButton.icon(
                  onPressed: onRestart,
                  icon: const Icon(Icons.refresh, color: SC.accent),
                  label: Text(
                    AppStrings.t('restart'),
                    style: const TextStyle(color: SC.accent),
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

class _Empty extends StatelessWidget {
  const _Empty({required this.onReset});
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: const Icon(
                Icons.favorite_border,
                color: Colors.white54,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.t('discover_empty_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('discover_empty_body'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.refresh, color: SC.accent),
              label: Text(
                AppStrings.t('restart'),
                style: const TextStyle(color: SC.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
