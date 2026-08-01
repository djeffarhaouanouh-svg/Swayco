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
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/nav_chrome.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/units.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/flag_border.dart';
import '../widgets/flag_gradients.dart';
import '../widgets/glass.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/match_overlay.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

/// Le fond du panneau déplié : opaque, un cran au-dessus du noir de la page —
/// assez pour qu'on voie où il commence quand il recouvre la photo, assez peu
/// pour rester du noir.
const Color _kPanelBg = Color(0xFF141517);

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
  }

  int _currentIndex = 0;
  final _stackKey = GlobalKey<_TinderCardStackState>();
  List<Friendship> _myFriendships = const [];

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
    if (_infoOpen || _cards.isEmpty) return;
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
      ]).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _myFriendships = results[0] as List<Friendship>;
        _profiles = results[1] as List<RemoteProfile>;
        _rebuildCards();
        final cursor = results[2] as String;
        if (cursor.isNotEmpty && _cards.isNotEmpty) {
          final idx = _cards.indexWhere((c) => c.profile.id == cursor);
          if (idx > 0) _currentIndex = idx;
        }
        _feedLoading = false;
      });
      AppBoot.markHomeReady();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _precacheAround(_currentIndex);
      });
    } catch (_) {
      if (mounted) setState(() => _feedLoading = false);
      AppBoot.markHomeReady();
    }
  }

  void _precacheAround(int index) {
    if (!mounted || _cards.isEmpty) return;
    final n = _cards.length;
    final seen = <String>{};
    for (var off = -1; off <= 5; off++) {
      for (final url in _cards[(index + off) % n].photos) {
        if (url.isNotEmpty && seen.add(url)) {
          precacheImage(NetworkImage(url), context).ignore();
        }
      }
    }
  }

  /// Swipe right = a like. If the peer had already liked me the likes meet
  /// and it's a match right away — celebrate it over the card stack.
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

  /// "It's a match!" over the Discover stack. "Dire bonjour" opens the DM.
  Future<void> _celebrateMatch(RemoteProfile peer) async {
    final me = isSupabaseReady ? await ProfileApi.fetchById(_myId) : null;
    if (!mounted) return;
    final peerName = peer.displayName.trim().isEmpty
        ? AppStrings.t('profile_anonymous')
        : peer.displayName;
    await showMatchOverlay(
      context,
      myName: me?.displayName ?? '',
      myPhotoUrl: me?.avatarUrl ?? '',
      theirName: peerName,
      theirPhotoUrl: peer.avatarUrl,
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
    if (isRight) {
      HapticFeedback.lightImpact();
      _likePeer(profile);
    }
    if (!mounted || _cards.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % _cards.length;
      UserPrefs.saveDiscoverCursor(_cards[_currentIndex % _cards.length].profile.id);
      _precacheAround(_currentIndex);
    });
  }

  void _onActionUndo() {
    if (_cards.isEmpty) return;
    setState(() => _currentIndex = (_currentIndex - 1 + _cards.length) % _cards.length);
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

  Future<void> _reset() async {
    if (_myId.isEmpty) return;
    setState(() { _feedLoading = true; _currentIndex = 0; });
    try {
      final feed = await ProfileApi.fetchDiscoverFeed(myId: _myId);
      if (!mounted) return;
      setState(() { _profiles = feed; _rebuildCards(); _feedLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _feedLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    const actionH = 92.0;
    // Boutons SOUS la carte, posés sur le fond noir (juste au-dessus de la nav).
    final btnBottom = GlassNavBar.totalReservedHeight + safeBottom + 10;
    // La carte (photo arrondie) s'arrête AU-DESSUS des boutons.
    final cardBottom = btnBottom + actionH + 14;
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
            left: 8,
            right: 8,
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
          if (!_feedLoading && _cards.isNotEmpty && !_infoOpen)
            Positioned(
              top: tabBarH + 20,
              left: 20,
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

          // ── Boutons action — sous la carte au repos, flottant PAR-DESSUS
          //    elle (sur le panneau) dès qu'il est déplié. ─────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: _infoOpen ? safeBottom + 4 : btnBottom,
            height: actionH,
            child: _SwipeActionBar(
              height: actionH,
              onNope: _onSwipeLeft,
              onLike: _onSwipeRight,
              onMessage: () {
                if (_cards.isEmpty) return;
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfileScreen(
                      userId:
                          _cards[_currentIndex % _cards.length].profile.id,
                    ),
                  ),
                );
              },
            ),
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
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
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
        final card = widget.cards[(widget.currentIndex + step) % n];
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
    final i = widget.currentIndex % n;

    return LayoutBuilder(
      builder: (context, c) {
        // Le panneau prend les trois quarts de la carte : assez pour poser la
        // bio, les faits et les intérêts d'un coup. La bande de photo qui
        // reste au-dessus sert de poignée pour le rabattre.
        final panelH = c.maxHeight * 0.76;
        return Stack(
        children: [
          // Back card (3rd)
          if (n >= 3)
            _StackCard(
              key: ValueKey('back_${(i + 2) % n}'),
              scale: 0.90,
              translateY: 18,
              child: _buildCard(widget.cards[(i + 2) % n]),
            ),
          // Middle card (2nd) — scales up as top card moves
          if (n >= 2)
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (_, p, child) => _StackCard(
                key: ValueKey('mid_${(i + 1) % n}'),
                scale: 0.95 + 0.05 * p.clamp(0.0, 1.0),
                translateY: 9 * (1 - p.clamp(0.0, 1.0)),
                child: _buildCard(widget.cards[(i + 1) % n]),
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
          // Au-dessus du panneau, la photo reste vivante : les taps
          // gauche/droite continuent de faire défiler le carrousel. Seul un
          // glissement vers le BAS est capté ici, pour rabattre le panneau —
          // d'où le translucent (il ne réclame pas le tap).
          if (widget.infoOpen)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: panelH,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
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
    return SizedBox.expand(
      child: country != null
          ? FlagBorder(
              country: country,
              radius: 24,
              child: tinderCard,
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: tinderCard,
            ),
    );
  }
}

/// Le panneau que la carte déplie : la bio d'abord, puis les infos que la
/// personne a choisi de partager (âge, taille, métier, signe, ce qu'elle
/// cherche), puis ses centres d'intérêt. Il reste DANS la carte — on ne change
/// pas de page — et se rabat d'un glissement vers le bas.
class _ProfileInfoPanel extends StatelessWidget {
  const _ProfileInfoPanel({required this.profile, required this.onClose});

  final RemoteProfile profile;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final place = [p.city.trim(), p.country.trim()]
        .where((e) => e.isNotEmpty)
        .join(', ');
    final facts = <({String emoji, String label})>[
      if (p.age != null)
        (emoji: kFactEmojiAge, label: AppStrings.t('info_age_value', args: {'n': '${p.age}'})),
      if (p.heightCm != null)
        // Pieds/pouces pour un profil américain, centimètres ailleurs.
        (emoji: kFactEmojiHeight, label: formatHeight(p.heightCm!, country: p.country)),
      if (p.job.trim().isNotEmpty)
        (emoji: kFactEmojiJob, label: p.job.trim()),
      if (p.zodiac.trim().isNotEmpty)
        (emoji: kFactEmojiZodiac, label: p.zodiac.trim()),
      if (p.lookingFor.trim().isNotEmpty)
        (emoji: kFactEmojiLookingFor, label: p.lookingFor.trim()),
      if (place.isNotEmpty)
        (emoji: kFactEmojiPlace, label: place),
      // Pas de ligne "langue" : le drapeau est déjà sur la photo, et l'app
      // traduit — savoir ce que l'autre parle ne change rien.
    ];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Un glissement vers le bas suffit à le rabattre — pas de bouton.
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 120) onClose();
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
                  // Ceinture : le panneau est taillé pour tout contenir (bio
                  // plafonnée à 80 caractères, un seul centre d'intérêt), donc
                  // il ne défile pas. Mais sur un très petit écran — ou pour un
                  // ancien profil à plusieurs intérêts — le contenu peut
                  // dépasser : la hauteur minimale rend alors la vue défilable
                  // au lieu de couper la fin.
                  child: LayoutBuilder(
                    builder: (ctx, c) => SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 96),
                    child: ConstrainedBox(
                      // 102 = le padding vertical ci-dessus ; sans lui la
                      // hauteur minimale déborderait toujours d'autant.
                      constraints: BoxConstraints(
                        minHeight: (c.maxHeight - 102).clamp(0.0, double.infinity),
                      ),
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
                        Text(
                          p.bio.trim(),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontSize: 15.5,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 22),
                      ],
                      if (facts.isNotEmpty) ...[
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
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 22),
                      ],
                      if (p.interests.isNotEmpty) ...[
                        _PanelSectionTitle(AppStrings.t('info_interests')),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final tag in p.interests)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.07),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.12),
                                  ),
                                ),
                                child: Text(
                                  interestLabel(tag),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.90),
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (p.bio.trim().isEmpty &&
                          facts.isEmpty &&
                          p.interests.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            AppStrings.t('info_empty'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                      ),
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

/// La première ligne du panneau : prénom, âge, et la paire de langues.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.profile});

  final RemoteProfile profile;

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.trim().isEmpty
        ? AppStrings.t('profile_anonymous')
        : profile.displayName.trim();
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
        if (profile.age != null) ...[
          const SizedBox(width: 9),
          Text(
            '${profile.age}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 21,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(width: 10),
        _LanguagePairChip(theirLang: profile.language),
      ],
    );
  }
}

/// « 🇫🇷 FR ⇄ EN 🇬🇧 » : sa langue, la mienne, et la flèche entre les deux.
///
/// C'est la seule chose de la fiche qui parle de MOI : tout le reste décrit la
/// personne, celle-ci dit ce qui se passera si on se parle. La flèche est en
/// cyan — c'est la traduction, pas une simple mention de langue.
class _LanguagePairChip extends StatelessWidget {
  const _LanguagePairChip({required this.theirLang});

  final String theirLang;

  @override
  Widget build(BuildContext context) {
    final theirs = findLanguageByCode(theirLang);
    final mine = findLanguageByCode(AppStrings.currentBcp47.value);
    // Une seule langue connue, ou la même des deux côtés : il n'y a pas de
    // paire à montrer.
    if (theirs == null || mine == null || theirs.code == mine.code) {
      return const SizedBox.shrink();
    }
    const code = TextStyle(
      color: Colors.white,
      fontSize: 12.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(theirs.flag, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          Text(theirs.code.toUpperCase(), style: code),
          const SizedBox(width: 5),
          const Icon(Icons.sync_alt_rounded, size: 13, color: SC.accent),
          const SizedBox(width: 5),
          Text(mine.code.toUpperCase(), style: code),
          const SizedBox(width: 6),
          Text(mine.flag, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

/// Une info du bloc « À propos » : son emoji, puis sa valeur. Une pastille par
/// fait, deux par ligne.
class _FactChip extends StatelessWidget {
  const _FactChip({required this.emoji, required this.label});

  final String emoji;
  final String label;

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
          Text(emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 14,
                fontWeight: FontWeight.w600,
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
    final likeOpacity = (_pos.dx / 65.0).clamp(0.0, 1.0);
    final nopeOpacity = (-_pos.dx / 65.0).clamp(0.0, 1.0);

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
              // LIKE à DROITE (le côté vers lequel on glisse pour liker),
              // NOPE à gauche.
              if (likeOpacity > 0.02)
                Positioned(
                  top: 36,
                  right: 24,
                  child: Opacity(
                    opacity: likeOpacity,
                    child: const _SwipeStamp(text: 'LIKE', color: Color(0xFF3DCA72)),
                  ),
                ),
              if (nopeOpacity > 0.02)
                Positioned(
                  top: 36,
                  left: 24,
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
    final online = !p.hideOnlineStatus &&
        p.lastSeen != null &&
        DateTime.now().difference(p.lastSeen!) < const Duration(minutes: 2);
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

          // ── Photo dots — en haut à DROITE ───────────────────────────────
          // Face au logo, pas au milieu : centrées, elles tombaient sous lui et
          // le haut de la carte avait deux choses empilées au même endroit.
          if (photos.length > 1)
            Positioned(
              // Descendues : collées au bord elles se perdaient dans l'encoche.
              top: 20,
              right: 16,
              child: _PhotoDots(count: photos.length, active: _photoIndex),
            ),

          // ── Bottom info + verre dépoli (épouse le contenu jusqu'en bas) ──
          // Verre dépoli décoratif au bas de la carte : il FOND en douceur
          // vers le haut (masque dégradé, pas de bord net) et reste concentré
          // Dégradé noir LISSE sur toute la carte (comme Tinder) — aucun
          // rectangle, aucun blur : transparent en haut, fondu progressif
          // jusqu'au noir en bas où reposent nom + boutons.
          // ── Bottom info (net, en bas de la carte photo) ──────────────────
          Positioned(
            left: 14,
            // Plus de bouton dans le coin : le bloc peut aller au bord.
            right: 20,
            // Prénom, ville et centres d'intérêt, posés au bas de l'image.
            bottom: 20,
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
                // Interests — données réelles Supabase uniquement
                if (p.interests.isNotEmpty) ...[
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
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in p.interests.take(6))
                        _InterestChip(label: interestLabel(tag)),
                    ],
                  ),
                ],
              ],
            ),
          ),

        ],
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

class _InterestChip extends StatelessWidget {
  const _InterestChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // Légère ombre derrière chaque chip d'intérêt.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Action bar — pass / like. The rewind arrow lives on the card now, and the
// super-like / send-a-message buttons are gone.
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeActionBar extends StatelessWidget {
  const _SwipeActionBar({
    required this.height,
    required this.onNope,
    required this.onLike,
    required this.onMessage,
  });

  final double height;
  final VoidCallback onNope;
  final VoidCallback onLike;

  /// Kept wired (the profile opens from here) even though no button surfaces
  /// it any more — the card itself opens the profile.
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _GlassButton(
            size: 58,
            iconSize: 27,
            icon: Icons.close_rounded,
            // Croix blanche : le rouge est réservé au cœur, sinon les deux
            // boutons se ressemblaient trop.
            color: Colors.white,
            onTap: onNope,
          ),
          const SizedBox(width: 28),
          _GlassButton(
            size: 58,
            iconSize: 27,
            // Une coche, pas un cœur : on valide quelqu'un, et le geste se
            // lit sans ambiguïté à côté de la croix.
            icon: Icons.check_rounded,
            // Le vert que ce bouton portait à l'origine.
            color: const Color(0xFF3DCA72),
            onTap: onLike,
          ),
        ],
      ),
    );
  }
}

/// Les deux boutons de match : des ronds en verre nu, une icône colorée au
/// centre (✕ blanche pour passer, ❤️ rouge pour liker) et un halo discret
/// derrière. Au clic, une onde de la couleur de l'icône part du cercle et se
/// dissipe — le geste reste visible même quand le pouce couvre le bouton.
class _GlassButton extends StatefulWidget {
  const _GlassButton({
    required this.size,
    required this.iconSize,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final double size;
  final double iconSize;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<_GlassButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  void _fire() {
    _ripple.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final color = widget.color;
    return Stack(
      // L'onde déborde du bouton : surtout ne pas la rogner.
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // L'onde vit dans une boîte de la TAILLE DU BOUTON et déborde en
        // peinture seulement (OverflowBox) : sans ça l'anneau élargissait le
        // Stack, la Row s'étirait, et les deux boutons s'écartaient à chaque
        // clic — l'animation restant à sa valeur finale, ils ne revenaient
        // même pas.
        SizedBox(
          width: size,
          height: size,
          child: IgnorePointer(
            child: OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: AnimatedBuilder(
                animation: _ripple,
                builder: (_, _) {
                  final t = _ripple.value;
                  // Au repos (jamais joué, ou terminé) : rien à dessiner.
                  if (t == 0 || t == 1) return const SizedBox.shrink();
                  // L'anneau grandit de moitié, s'affine et s'efface.
                  final d = size * (1 + 0.9 * t);
                  return Opacity(
                    opacity: (1 - t) * 0.55,
                    child: Container(
                      width: d,
                      height: d,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color,
                          width: 0.5 + 2.5 * (1 - t),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Pressable(
      bounce: true,
      onTap: _fire,
      child: DecoratedBox(
        // Depth + coloured glow sit OUTSIDE the clip so they aren't cut off.
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            // Ombres plus discrètes — effet léger/premium.
            BoxShadow(
              color: color.withValues(alpha: 0.16),
              blurRadius: 12,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Verre nu : ni teinte cyan, ni reflet. Seule l'icône est
                // colorée, le cercle laisse passer la photo.
                color: Colors.white.withValues(alpha: 0.12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                  width: 0.8,
                ),
              ),
              child: Center(
                child: Icon(widget.icon, color: color, size: widget.iconSize),
              ),
            ),
          ),
        ),
      ),
        ),
      ],
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
// Empty state
// ══════════════════════════════════════════════════════════════════════════════

class _Empty extends StatelessWidget {
  const _Empty({required this.onReset});
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
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
            child: const Icon(Icons.favorite_border, color: Colors.white54, size: 32),
          ),
          const SizedBox(height: 16),
          const Text(
            'Vous avez tout vu !',
            style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.refresh, color: Color(0xFF3DCA72)),
            label: const Text(
              'Recommencer',
              style: TextStyle(color: Color(0xFF3DCA72)),
            ),
          ),
        ],
      ),
    );
  }
}
