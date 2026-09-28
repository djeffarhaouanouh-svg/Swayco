import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/ad_service.dart';
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
import '../services/revenue_cat.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../services/zodiac.dart';
import '../theme/swayco_theme.dart';
import '../widgets/country_silhouette.dart';
import '../widgets/discover_globe.dart';
import '../widgets/flag_border.dart';
import '../widgets/flag_gradients.dart';
import '../widgets/glass.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/interest_chip.dart';
import '../widgets/liquid_glass_button.dart';
import '../widgets/lottie_icon_transition.dart';
import '../widgets/match_overlay.dart';
import '../widgets/swipe_coach_overlay.dart';
import '../widgets/translated_profile_text.dart';
import 'chat_thread_screen.dart';
import 'paywall_screen.dart';
import 'profile_screen.dart';

/// Le fond du panneau déplié : opaque, un cran au-dessus du noir de la page —
/// assez pour qu'on voie où il commence quand il recouvre la photo, assez peu
/// pour rester du noir.
const Color _kPanelBg = Color(0xFF141517);

/// Marge latérale de la carte (handoff 3c).
const double _kCardInset = 14.0;

/// Rayon des coins de la carte photo (handoff 3c).
const double _kCardRadius = 32.0;

/// Diamètre des boutons ✕ / message / ❤.
const double _kActionSize = 58.0;

/// Respiration au-dessus et au-dessous de la rangée ✕ / message / ❤.
const double _kActionPadV = 16.0;

/// Surfaces pleines du handoff : bulles pays, bouton message.
const Color _kSurface = Color(0xFF1A1A1D);
const Color _kSurfaceBorder = Color(0xFF2A2A2E);

/// L'or de l'accès privilégié — jamais de cyan sur une action payante.
const Color _kGold = Color(0xFFF5C451);

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
    if (_cards.isNotEmpty && !_filtered) {
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
    if (!_filtered) {
      UserPrefs.clearDiscoverDone();
      UserPrefs.saveDiscoverCursor(_cards.first.profile.id);
    }
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

  Timer? _pollTimer;
  String _myId = '';

  /// The card's info panel: pulled up from the photo, folded back down by a
  /// drag or a tap on the scrim. While it's open the nav bar slides away and
  /// the ✕ / ♥ float on top of the card.
  bool _infoOpen = false;

  /// Countries picked on the globe filter bar (world-atlas keys, e.g.
  /// {'France', 'Germany'}), empty for the unfiltered deck. When non-empty the
  /// feed is reloaded filtered to those countries' spoken languages and today's
  /// deck state is NOT persisted (the filtered view is ephemeral).
  Set<String> _countryKeys = {};
  bool get _filtered => _countryKeys.isNotEmpty;

  // Ring+Arrow transition shown while the globe-filtered feed loads — hidden
  // once BOTH the clip has played through AND the feed has actually landed,
  // so a slow network doesn't cut the animation short.
  bool _showFilterTransition = false;
  bool _transitionAnimDone = false;
  bool _transitionFeedDone = false;

  void _maybeHideFilterTransition() {
    if (_transitionAnimDone && _transitionFeedDone && mounted) {
      setState(() => _showFilterTransition = false);
    }
  }

  List<String> get _filterCountries => _countryKeys
      .map(globeCountryDbName)
      .whereType<String>()
      .toSet()
      .toList();

  /// Opens the spinning-globe country picker (multi-select). A non-empty
  /// result reloads the feed filtered to those countries (the peer's actual
  /// `profiles.country`, not what they speak).
  Future<void> _openGlobe() async {
    final keys = await showGeneralDialog<Set<String>>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => DiscoverGlobeSheet(initial: _countryKeys),
      transitionBuilder: (_, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
          child: child,
        ),
      ),
    );
    if (!mounted || keys == null || keys.isEmpty) return;
    setState(() {
      _countryKeys = keys;
      _showFilterTransition = true;
      _transitionAnimDone = false;
      _transitionFeedDone = false;
    });
    Analytics.track('screen_view',
        props: {'screen': 'discover', 'country_filter': keys.join(',')});
    await _loadFeed(countries: _filterCountries);
    if (!mounted) return;
    _transitionFeedDone = true;
    _maybeHideFilterTransition();
  }

  void _clearCountryFilter() {
    if (_countryKeys.isEmpty) return;
    setState(() => _countryKeys = {});
    _loadFeed(countries: null);
  }

  /// A bubble of the country row: filters the deck to that one country, or
  /// clears the filter when it's already the only one picked.
  Future<void> _toggleCountry(String key) async {
    if (_countryKeys.length == 1 && _countryKeys.contains(key)) {
      _clearCountryFilter();
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _countryKeys = {key};
      _showFilterTransition = true;
      _transitionAnimDone = false;
      _transitionFeedDone = false;
    });
    Analytics.track('screen_view',
        props: {'screen': 'discover', 'country_filter': key, 'source': 'row'});
    await _loadFeed(countries: _filterCountries);
    if (!mounted) return;
    _transitionFeedDone = true;
    _maybeHideFilterTransition();
  }

  /// The gold button: write to the card's person without matching first.
  /// Premium only — everyone else gets the paywall.
  Future<void> _directMessage() async {
    if (!_hasActiveCard) return;
    final peer = _cards[_currentIndex].profile;
    if (!RevenueCat.proActive.value) {
      Analytics.track('paywall_open', props: {'source': 'discover_direct_message'});
      await showPaywallSheet(context);
      if (!mounted || !RevenueCat.proActive.value) return;
    }
    final ids = [_myId, peer.id]..sort();
    final name = peer.displayName.trim().isEmpty
        ? AppStrings.t('profile_anonymous')
        : peer.displayName.trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatThreadScreen(
          conversationId: 'dm-${ids[0]}-${ids[1]}',
          title: name,
          peerDeviceId: peer.id,
        ),
      ),
    );
  }

  /// Reloads the Discover deck, optionally filtered by peer [countries].
  Future<void> _loadFeed({required List<String>? countries}) async {
    if (_myId.isEmpty || !isSupabaseReady) return;
    setState(() {
      _feedLoading = true;
      _currentIndex = 0;
      _deckDone = false;
      _infoOpen = false;
    });
    NavChrome.show();
    try {
      final feed = await ProfileApi.fetchDiscoverFeed(
        myId: _myId,
        countries: countries,
      ).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _profiles = feed;
        _rebuildCards();
        _feedLoading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_deckDone) _precacheAround(0);
      });
    } catch (e) {
      debugPrint('discover: _loadFeed(countries=$countries) failed: $e');
      if (mounted) setState(() => _feedLoading = false);
    }
  }

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

  // "Glisse pour choisir" one-shot coach — the very first time this screen
  // is reached (right after onboarding). Starts closed: it only opens once
  // the flag lookup confirms it has never played.
  bool _showSwipeCoach = false;

  @override
  void initState() {
    super.initState();
    Analytics.track('screen_view', props: {'screen': 'discover'});
    _bootstrap();
    _maybeShowSwipeCoach();
    _pollTimer = WebPoll.every(const Duration(seconds: 12), _refreshFriendships);
    // Warm up the "Discover" interstitial in the background so one is ready
    // the moment something calls AdService.showDiscoverInterstitial() — no
    // such call site exists yet in this first step, only the mechanism.
    // No-ops for Pro subscribers and never blocks/throws on failure.
    unawaited(AdService.preload());
  }

  Future<void> _maybeShowSwipeCoach() async {
    if (await UserPrefs.isSwipeCoachSeen()) return;
    await UserPrefs.markSwipeCoachSeen();
    if (!mounted) return;
    setState(() => _showSwipeCoach = true);
  }

  @override
  void dispose() {
    NavChrome.show();
    _pollTimer?.cancel();
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

  /// Called on a like (swipe right or the heart button). If the peer had
  /// already liked me the likes meet and it's a match right away —
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

  void _onCardSwiped(bool isRight, RemoteProfile profile) {
    _closeInfo();
    // Standard Tinder convention: dragging/flying RIGHT is the like, LEFT
    // the refuse.
    if (isRight) {
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
      if (!_filtered) {
        UserPrefs.markDiscoverDoneToday();
        UserPrefs.saveDiscoverCursor('');
      }
      return;
    }
    setState(() {
      _currentIndex = next;
      _deckDone = false;
      if (!_filtered) {
        UserPrefs.saveDiscoverCursor(_cards[_currentIndex].profile.id);
      }
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
    // Handoff 3c, de haut en bas : logo · rangée de pays · carte · ✕ ✉ ❤ ·
    // nav. La rangée d'actions se pose sur la nav avec sa propre respiration
    // (16 dessus, 16 dessous) — plus de bande blanche.
    final btnBottom =
        GlassNavBar.totalReservedHeight + safeBottom + _kActionPadV;
    final cardBottom = btnBottom + _kActionSize + _kActionPadV;
    final headerBottom = safeTop + _DiscoverHeader.height + _CountryRow.height;

    // Panneau ouvert : la carte prend toute la hauteur — elle monte par-dessus
    // le logo et les pays, et descend dans l'espace libéré par la nav. Le
    // panneau y gagne assez de place pour tout montrer sans défiler.
    final openCardBottom = safeBottom + 12;
    final currentCardBottom = _infoOpen ? openCardBottom : cardBottom;
    final currentCardTop = _infoOpen ? safeTop + 4 : headerBottom;

    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: Stack(
        children: [
          // ── Logo + rangée de pays. AVANT la carte dans la pile : panneau
          //    ouvert, la carte monte et les recouvre. ──────────────────────
          Positioned(
            top: safeTop,
            left: 0,
            right: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _DiscoverHeader(),
                _CountryRow(
                  selected: _countryKeys,
                  onFilter: _openGlobe,
                  onCountry: _toggleCountry,
                ),
              ],
            ),
          ),

          // ── Card ─────────────────────────────────────────────────────────
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
                    ? _Empty(
                        onReset: _filtered ? _clearCountryFilter : _reset,
                        body: _filtered
                            ? AppStrings.t('globe_filter_empty')
                            : null,
                      )
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
                            // Le retour vit DANS la carte : il glisse avec
                            // elle au swipe. Retiré pendant la transition
                            // "Go" et le panneau infos.
                            topRightBadge:
                                (!_infoOpen && !_showFilterTransition)
                                    ? _CardUndoButton(onTap: _onActionUndo)
                                    : null,
                          ),
          ),

          // ── Transition "Go" du filtre globe — icône Ring+Arrow (SANS
          //    wordmark, contrairement au splash de boot) + un "Chargement"
          //    séparé, plus haut et plus grand que le wordmark du boot (celui-là
          //    est du texte de statut à lire, pas une signature discrète en
          //    bas d'écran). ──────────────────────────────────────────────
          if (_showFilterTransition)
            Positioned.fill(
              child: Stack(
                children: [
                  LottieIconTransition(
                    asset: 'assets/discover_filter_transition.json',
                    onComplete: () {
                      _transitionAnimDone = true;
                      _maybeHideFilterTransition();
                    },
                  ),
                  Align(
                    alignment: const Alignment(0, 0.6),
                    child: Text(
                      AppStrings.t('profile_loading'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── ✕ · message direct · ❤ — sous la carte au repos, flottant
          //    PAR-DESSUS elle (sur le panneau) dès qu'il est déplié. ─────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: _infoOpen ? safeBottom + 8 : btnBottom,
            height: _kActionSize,
            child: _hasActiveCard && !_showFilterTransition
                ? _SwipeActionBar(
                    onNope: _onSwipeLeft,
                    onLike: _onSwipeRight,
                    onMessage: _directMessage,
                  )
                : const SizedBox.shrink(),
          ),

          // ── Coach "glisse pour choisir" — une seule fois, à l'arrivée ────
          if (_showSwipeCoach)
            SwipeCoachOverlay(
              onDismiss: () => setState(() => _showSwipeCoach = false),
            ),
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
// Header — le logo swaycø, seul (handoff 3c : pas de loupe)
// ══════════════════════════════════════════════════════════════════════════════

class _DiscoverHeader extends StatelessWidget {
  const _DiscoverHeader();

  /// Hauteur sous la safe area : logo 42 + respiration.
  static const double height = 52.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SvgPicture.asset(
            'assets/swayco_logo_6d.svg',
            height: 42,
            semanticsLabel: 'swaycø',
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Rangée de pays — « Filtrer » (le globe) + cinq pays en un tap
// ══════════════════════════════════════════════════════════════════════════════

/// Les pays de la rangée, dans l'ordre du handoff. `key` est la clé du globe
/// ([kGlobeCountries], qui porte aussi le nom stocké en base), `geo` le nom
/// dans le GeoJSON, `label` la clé de traduction du libellé.
const _kRowCountries = <({String key, String geo, String iso, String label})>[
  (key: 'France', geo: 'France', iso: 'fr', label: 'country_fr'),
  (key: 'Spain', geo: 'Spain', iso: 'es', label: 'country_es'),
  (key: 'Brazil', geo: 'Brazil', iso: 'br', label: 'country_br'),
  (key: 'Sweden', geo: 'Sweden', iso: 'se', label: 'country_se'),
  (key: 'Morocco', geo: 'Morocco', iso: 'ma', label: 'country_ma'),
];

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required this.selected,
    required this.onFilter,
    required this.onCountry,
  });

  final Set<String> selected;
  final VoidCallback onFilter;
  final ValueChanged<String> onCountry;

  /// Bulle 44 + 6 + libellé 14, et 12 de marge dessus / dessous.
  static const double height = 12 + 44 + 6 + 14 + 12;

  @override
  Widget build(BuildContext context) {
    // Filtré depuis le globe sur un pays hors de la rangée : c'est « Filtrer »
    // qui le signale, aucune bulle ne pouvant s'allumer pour lui.
    final rowKeys = {for (final c in _kRowCountries) c.key};
    final filterActive = selected.any((k) => !rowKeys.contains(k));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RowItem(
            label: AppStrings.t('globe_filter_cta'),
            active: filterActive,
            onTap: onFilter,
            // Pas de verre dans la rangée : la bulle « Filtrer » est pleine,
            // comme les bulles pays.
            bubble: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _kSurface,
                    shape: BoxShape.circle,
                    border: Border.all(color: _kSurfaceBorder, width: 2),
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                if (filterActive)
                  Positioned(
                    top: -1,
                    right: -1,
                    child: IgnorePointer(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: SC.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: SC.bg, width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (final c in _kRowCountries)
            _RowItem(
              label: AppStrings.t(c.label),
              active: selected.contains(c.key),
              onTap: () => onCountry(c.key),
              bubble: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _kSurface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected.contains(c.key)
                        ? SC.accent
                        : _kSurfaceBorder,
                    width: 2,
                  ),
                ),
                alignment: Alignment.center,
                child: CountrySilhouette(geoName: c.geo, iso2: c.iso),
              ),
            ),
        ],
      ),
    );
  }
}

class _RowItem extends StatelessWidget {
  const _RowItem({
    required this.bubble,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final Widget bubble;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            bubble,
            const SizedBox(height: 6),
            SizedBox(
              height: 14,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: active ? SC.accent : const Color(0xFFAAAAAA),
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
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
    this.topRightBadge,
  });

  final List<({RemoteProfile profile, List<String> photos})> cards;
  final int currentIndex;
  final void Function(bool isRight, RemoteProfile profile) onSwiped;

  /// Dragging the photo upward asks for the info panel.
  final VoidCallback onPullUp;

  /// True while that panel is up — it covers the bottom half of the card.
  final bool infoOpen;
  final VoidCallback onCloseInfo;

  /// Chip pinned to the top card's corner (it rides the swipe transform).
  final Widget? topRightBadge;

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

    // Les deux cartes fantômes (handoff 3c : +4° / −3°) dépassent du cadre de
    // la carte — elles vivent donc HORS du clip. Tout le reste (la carte, la
    // suivante, le panneau caché sous le bord) reste rogné au rectangle.
    // Une fantôme par carte restante, jamais plus de deux : la pile ne ment
    // pas sur ce qu'il reste à voir. Rangées pendant que le panneau est ouvert.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (hasBack && !widget.infoOpen)
          const _GhostCard(angleDeg: -3),
        if (hasMid && !widget.infoOpen)
          const _GhostCard(angleDeg: 4),
        Positioned.fill(child: ClipRect(child: _buildStack(i, hasMid))),
      ],
    );
  }

  Widget _buildStack(int i, bool hasMid) {
    return LayoutBuilder(
      builder: (context, c) {
        // Le panneau prend les trois quarts de la carte : assez pour poser la
        // bio, les faits et les intérêts d'un coup. La bande de photo qui
        // reste au-dessus sert de poignée pour le rabattre.
        final panelH = c.maxHeight * 0.76;
        return Stack(
        children: [
          // Carte suivante — pleine taille dessous, elle grandit à mesure
          // que celle du dessus s'en va.
          if (hasMid)
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (_, p, child) => _StackCard(
                key: ValueKey('mid_${i + 1}'),
                scale: 0.96 + 0.04 * p.clamp(0.0, 1.0),
                translateY: 0,
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
              topRightBadge: widget.topRightBadge,
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
    // Carte photo arrondie (32) qui flotte sur le fond noir — plus de liseré
    // drapeau : le drapeau est à côté du prénom, en image.
    return SizedBox.expand(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_kCardRadius),
        child: _TinderCard(
          key: ValueKey(card.profile.id),
          profile: card.profile,
          photos: card.photos,
        ),
      ),
    );
  }
}

/// Une carte fantôme : la tranche de la pile qui dépasse derrière la carte,
/// inclinée de [angleDeg]. Pas de photo — juste la surface, un cran plus
/// petite et descendue de 10 : elle ne se voit que sous la carte et par ses
/// coins.
class _GhostCard extends StatelessWidget {
  const _GhostCard({required this.angleDeg});

  final double angleDeg;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Transform.translate(
          offset: const Offset(0, 10),
          child: Transform.rotate(
          angle: angleDeg * 3.141592653589793 / 180,
          child: Transform.scale(
            scale: 0.96,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _kSurface,
                borderRadius: BorderRadius.circular(_kCardRadius),
                border: Border.all(color: _kSurfaceBorder),
              ),
            ),
          ),
          ),
        ),
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
                            // Palette cyclique par position (handoff « Relief
                            // 3D ») : vert, orange, magenta, bleu…
                            for (var k = 0; k < p.interests.length; k++)
                              InterestTagChip(
                                label: p.interests[k],
                                color: interestPaletteColor(k),
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
    final flag = countryFlagFor(profile.country) ??
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
    this.topRightBadge,
  });
  final Widget child;
  final ValueChanged<bool> onSwiped;
  final ValueChanged<double> onProgress;

  /// Fired when the gesture was a real upward pull — the info panel opens
  /// instead of the card flying off.
  final VoidCallback? onPullUp;

  /// True while the panel is up: the card must not swipe under it.
  final bool locked;

  /// Floating chip pinned to the card's top-right corner (undo). It lives
  /// INSIDE the card's transform so it slides and tilts with it during a
  /// swipe.
  final Widget? topRightBadge;

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
    // Standard Tinder convention: LIKE tracks the right drag, NOPE the left one.
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
            clipBehavior: Clip.none,
            children: [
              widget.child,
              // LIKE à DROITE (le côté vers lequel on glisse pour matcher),
              // NOPE à gauche — convention Tinder standard.
              // Descendus sous la pastille filtre / le bouton retour, sinon
              // ils passaient à moitié dessous et on ne les voyait pas.
              if (likeOpacity > 0.02)
                Positioned(
                  top: 66,
                  right: 24,
                  child: Opacity(
                    opacity: likeOpacity,
                    child: const _SwipeStamp(text: 'LIKE', color: Color(0xFF3DCA72)),
                  ),
                ),
              if (nopeOpacity > 0.02)
                Positioned(
                  top: 66,
                  left: 24,
                  child: Opacity(
                    opacity: nopeOpacity,
                    child: const _SwipeStamp(text: 'NOPE', color: Color(0xFFFF4458)),
                  ),
                ),
              // Pastille filtre / retour — dans le transform de la carte, donc
              // elles glissent et s'inclinent avec elle.
              if (widget.topRightBadge != null)
                Positioned(top: 12, right: 12, child: widget.topRightBadge!),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color, width: 2.5),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
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

    final name = p.displayName.trim().isEmpty ? '—' : p.displayName.trim();
    final title = p.age != null ? '$name, ${p.age}' : name;
    // La ville seule (« Stockholm ») : le pays, lui, est dans le drapeau.
    final place = p.city.trim().isNotEmpty ? p.city.trim() : p.country.trim();
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

          // ── Dégradé noir en bas (style Tinder) — transparent sur le haut,
          //    fondu progressif jusqu'au noir sous le nom / la ville, pour que
          //    le texte reste lisible sur n'importe quelle photo. ────────────
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(0, 0.15),
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
              ),
            ),
          ),

          // ── Bas de carte (handoff 3c) : « Elin, 23 » + drapeau · ville ·
          //    puces. Pas de pastille « en ligne », pas de « points communs ».
          Positioned(
            left: 20,
            right: 20,
            bottom: 22,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tap sur le prénom → la page profil.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => ProfileScreen(userId: p.id),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.4,
                            height: 1.1,
                            shadows: [
                              Shadow(color: Color(0x66000000), blurRadius: 10),
                            ],
                          ),
                        ),
                      ),
                      if (p.isPro) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.verified_rounded,
                            color: Color(0xFF60A5FA), size: 22),
                      ],
                      const SizedBox(width: 10),
                      _NameFlag(profile: p),
                    ],
                  ),
                ),
                if (place.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    place,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(color: Color(0x66000000), blurRadius: 8),
                      ],
                    ),
                  ),
                ],
                _CardPills(profile: p),
              ],
            ),
          ),
        ],
      );
  }
}

/// Le drapeau posé après le prénom : l'EMOJI, le même que sur la page
/// Messages (le handoff voulait une image 28×19 — refusé, 2026-09-29). Celui
/// du PAYS ; à défaut, celui de la langue parlée.
class _NameFlag extends StatelessWidget {
  const _NameFlag({required this.profile});

  final RemoteProfile profile;

  @override
  Widget build(BuildContext context) {
    final flag = countryFlagFor(profile.country) ??
        findLanguageByCode(profile.language)?.flag ??
        '';
    if (flag.isEmpty) return const SizedBox.shrink();
    return Text(flag, style: const TextStyle(fontSize: 24, height: 1));
  }
}

/// Les puces sous la ville : ce qui définit la personne (sa catégorie
/// « persona ») d'abord, puis ses centres d'intérêt, chacun avec son emoji.
///
/// Une seule ligne, jamais coupée : on mesure chaque puce et on n'affiche que
/// celles qui tiennent EN ENTIER dans la largeur — une puce tronquée ou une
/// deuxième ligne mangerait la photo. Le reste est dans le panneau.
class _CardPills extends StatelessWidget {
  const _CardPills({required this.profile});

  final RemoteProfile profile;

  static const double _gap = 8;
  static const double _padH = 12;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final labels = <String>[
      if (personaCategoryByLabel(p.personaCategory) case final cat?)
        '${cat.emoji} ${personaCategoryLabel(p.personaCategory)}',
      for (final tag in p.interests)
        [interestEmoji(tag), interestLabel(tag)]
            .where((s) => s.isNotEmpty)
            .join(' '),
    ];
    if (labels.isEmpty) return const SizedBox.shrink();

    const style = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: LayoutBuilder(
        builder: (context, c) {
          final scaler = MediaQuery.textScalerOf(context);
          final fitting = <String>[];
          var used = 0.0;
          for (final label in labels) {
            final tp = TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final w = tp.width + _padH * 2 + 2; // +2 : la bordure.
            tp.dispose();
            final next = used + (fitting.isEmpty ? 0 : _gap) + w;
            if (next > c.maxWidth) break;
            fitting.add(label);
            used = next;
          }
          return Row(
            children: [
              for (var k = 0; k < fitting.length; k++) ...[
                if (k > 0) const SizedBox(width: _gap),
                _CardPill(label: fitting[k], style: style),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _CardPill extends StatelessWidget {
  const _CardPill({required this.label, required this.style});

  final String label;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: _CardPills._padH,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Text(label, maxLines: 1, softWrap: false, style: style),
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
// Barre d'actions — ✕ (verre) · message direct (or, Premium) · ❤ (verre)
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeActionBar extends StatelessWidget {
  const _SwipeActionBar({
    required this.onNope,
    required this.onLike,
    required this.onMessage,
  });

  final VoidCallback onNope;
  final VoidCallback onLike;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LiquidGlassButton(
          icon: Icons.close_rounded,
          sfSymbol: 'xmark',
          iconSize: 24,
          onTap: onNope,
          semanticLabel: 'Nope',
        ),
        const SizedBox(width: 18),
        _DirectMessageButton(onTap: onMessage),
        const SizedBox(width: 18),
        LiquidGlassButton(
          icon: Icons.favorite_rounded,
          sfSymbol: 'heart.fill',
          iconSize: 26,
          iconColor: const Color(0xFFFF5A7A),
          onTap: onLike,
          semanticLabel: 'Like',
        ),
      ],
    );
  }
}

/// Le message direct — l'accès privilégié, donc en OR (jamais de cyan sur une
/// action payante). Rond plein #1A1A1D cerclé d'or, bulle en dégradé or,
/// étoile ✦ en haut à droite, et un anneau qui pulse en boucle pour dire
/// qu'il se passe quelque chose de spécial ici.
class _DirectMessageButton extends StatefulWidget {
  const _DirectMessageButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_DirectMessageButton> createState() => _DirectMessageButtonState();
}

class _DirectMessageButtonState extends State<_DirectMessageButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2300),
  )..repeat();
  bool _pressed = false;

  static const _goldGradient = LinearGradient(
    // 145° CSS : du haut-gauche vers le bas-droite.
    begin: Alignment(-0.57, -0.82),
    end: Alignment(0.57, 0.82),
    colors: [Color(0xFFFBE7A1), Color(0xFFE9B949), Color(0xFFC48E22)],
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Message',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: SizedBox(
            width: _kActionSize,
            height: _kActionSize,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Anneau pulsé : 1 → 1.42, opacité .65 → 0, ease-out.
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, _) {
                    final t = Curves.easeOut.transform(_pulse.value);
                    return IgnorePointer(
                      child: Transform.scale(
                        scale: 1 + 0.42 * t,
                        child: Container(
                          width: _kActionSize,
                          height: _kActionSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _kGold.withValues(alpha: 0.65 * (1 - t)),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Container(
                  width: _kActionSize,
                  height: _kActionSize,
                  decoration: BoxDecoration(
                    color: _kSurface,
                    shape: BoxShape.circle,
                    border: Border.all(color: _kGold, width: 2),
                  ),
                  alignment: Alignment.center,
                  // Le dégradé ne teinte que l'icône : aucun flou dessous,
                  // donc pas de piège ShaderMask × BackdropFilter.
                  child: ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (r) => _goldGradient.createShader(r),
                    child: const Icon(
                      Icons.chat_bubble_rounded,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                ),
                // ✦ en haut à droite : fond de page, liseré or.
                Positioned(
                  top: -3,
                  right: -3,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: SC.bg,
                      shape: BoxShape.circle,
                      border: Border.all(color: _kGold, width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '✦',
                      style: TextStyle(
                        color: _kGold,
                        fontSize: 10,
                        height: 1,
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

/// Le retour arrière posé sur la photo : 44, verre sombre (black .22, blur
/// 12), sans bordure, icône blanche. Verre Flutter et non natif : une
/// platform view dans la carte qu'on balaie scintillait (commit 051f0fd).
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
              color: Colors.white,
              size: 22,
            ),
          ),
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
  const _Empty({required this.onReset, this.body});
  final VoidCallback onReset;

  /// Override for the sub-line — used by the country filter's empty state.
  final String? body;

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
              body ?? AppStrings.t('discover_empty_body'),
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
