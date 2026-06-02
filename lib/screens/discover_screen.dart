import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
import '../services/like_api.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/mesh_background.dart';
import '../widgets/emoji_burst.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with SingleTickerProviderStateMixin {
  // Real Supabase profiles, hydrated from ProfileApi.fetchDiscoverFeed at
  // bootstrap. Excludes me and anyone I've blocked / who's blocked me, but
  // intentionally KEEPS people I follow so their new photos show up here.
  List<RemoteProfile> _profiles = const <RemoteProfile>[];
  bool _feedLoading = true;

  // The feed is now one card per PHOTO, not per profile: every profile is
  // flattened into its photos (newest first), so a friend's new photos each
  // get their own swipeable card. Rebuilt whenever [_profiles] changes.
  final List<({RemoteProfile profile, String photo})> _cards = [];

  void _rebuildCards() {
    _cards.clear();
    for (final p in _profiles) {
      final photos = p.photos.where((u) => u.isNotEmpty).toList();
      if (photos.isEmpty) {
        // Legacy rows with no gallery: fall back to the single photo.
        final single = p.discoverPhotoUrl.isNotEmpty
            ? p.discoverPhotoUrl
            : p.avatarUrl;
        if (single.isNotEmpty) _cards.add((profile: p, photo: single));
      } else {
        // Newest photos sit at the end of the array (append-on-upload), so
        // reverse to show the most recent first.
        for (final url in photos.reversed) {
          _cards.add((profile: p, photo: url));
        }
      }
    }
  }

  // Profile ids I've already liked — heart renders filled for these.
  // Hydrated from Supabase on bootstrap so the state survives restarts /
  // multi-device; mutated optimistically on every tap, written through
  // LikeApi.like / LikeApi.unlike.
  Set<String> _likedIds = <String>{};

  // peer id → set of photo-reaction emojis I've already sent them.
  // Same persistence story as [_likedIds]: hydrated from the messages
  // table on bootstrap so each reaction button on a Discover card
  // renders pre-filled when I revisit.
  Map<String, Set<String>> _myReactionsByPeer = const {};

  // Discover PHOTOS I've already sent a direct intro message from (text area).
  // One message per photo (each photo is its own card), hydrated on bootstrap
  // so it survives restarts; the in-card field collapses to a sent state when
  // the card's photo is here.
  Set<String> _directMessagedPhotos = <String>{};

  // TikTok-style vertical pager. Swipe up = next profile, swipe down =
  // previous. Snapping + the slide animation are handled by PageView.
  final PageController _pageController = PageController();

  // Desktop mouse wheel / trackpad scrolls bypass PageView's snap and
  // can blow through several pages in one gesture. We debounce wheel
  // ticks here so one tick == one page change regardless of speed.
  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);

  // Inline search state — bar expands, dropdown of matching profiles below.
  bool _searchExpanded = false;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _searchDebounce;
  Timer? _pollTimer;
  String _myId = '';
  bool _searching = false;
  List<RemoteProfile> _searchResults = const [];
  // Friendship rows involving me — used to label each result with its
  // existing status (pending / accepted) so we don't show "send" twice.
  List<Friendship> _myFriendships = const [];

  // Idle swipe-hint: after [_swipeHintDelay] of inactivity, the deck peeks
  // the next card up and an up-arrow rides along (same controller, so they
  // move in sync). Any swipe / touch resets it.
  Timer? _swipeHintTimer;
  bool _showSwipeHint = false;
  static const _swipeHintDelay = Duration(seconds: 7);
  // Drives both the card peek (via PageController.jumpTo) and the arrow's
  // translation, so the two animate together.
  late final AnimationController _hintCtrl;
  // Page offset the nudge started from, restored when it finishes.
  double _nudgeStart = 0;
  // True while [_hintCtrl] is actively driving the page peek.
  bool _nudging = false;
  // How far the next card peeks up during the nudge.
  static const double _peek = 34;

  @override
  void initState() {
    super.initState();
    _hintCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 380),
    )..addListener(_onHintTick);
    _bootstrapSearch();
    _scheduleSwipeHint();
    // Web: periodically refresh friendships + likes so a peer accepting
    // / blocking / liking gets reflected on the Discover cards within
    // ~10s. The feed itself is not re-fetched (it'd reset the swipe
    // position) — only the lightweight signal queries.
    _pollTimer = WebPoll.every(
      const Duration(seconds: 10),
      _refreshLiveSignals,
    );
  }

  /// Lightweight refresh: only re-pulls friendship rows + likes I've
  /// given. Keeps the card stack and `_topIndex` exactly where they are.
  Future<void> _refreshLiveSignals() async {
    if (_myId.isEmpty || !isSupabaseReady) return;
    try {
      final mine = await FriendshipApi.fetchMine(_myId);
      final liked = await LikeApi.fetchMyLikedIds(_myId);
      final reactions = await ChatApi.fetchMyOutgoingPhotoReactions(_myId);
      final messaged = await ChatApi.fetchMyMessagedPhotos(_myId);
      if (!mounted) return;
      setState(() {
        _myFriendships = mine;
        _likedIds = liked;
        _myReactionsByPeer = reactions;
        _directMessagedPhotos = messaged;
      });
    } catch (_) {
      // Polling errors are non-fatal — next tick will retry.
    }
  }

  Future<void> _bootstrapSearch() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    if (!isSupabaseReady || id.isEmpty) {
      setState(() => _feedLoading = false);
      return;
    }
    try {
      final mine = await FriendshipApi.fetchMine(id);
      final liked = await LikeApi.fetchMyLikedIds(id);
      final reactions = await ChatApi.fetchMyOutgoingPhotoReactions(id);
      final messaged = await ChatApi.fetchMyMessagedPhotos(id);
      final feed = await ProfileApi.fetchDiscoverFeed(myId: id);
      if (!mounted) return;
      setState(() {
        _myFriendships = mine;
        _likedIds = liked;
        _myReactionsByPeer = reactions;
        _directMessagedPhotos = messaged;
        _profiles = feed;
        _rebuildCards();
        _feedLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _feedLoading = false);
    }
  }

  /// Toggle a like on [profileId]. Optimistic local flip + DB write
  /// through LikeApi; on error roll back so the heart matches the truth.
  Future<void> _toggleLikeOnProfile(String profileId) async {
    if (_myId.isEmpty || profileId.isEmpty) return;
    final wasLiked = _likedIds.contains(profileId);
    setState(() {
      if (wasLiked) {
        _likedIds = {..._likedIds}..remove(profileId);
      } else {
        _likedIds = {..._likedIds, profileId};
      }
    });
    try {
      if (wasLiked) {
        await LikeApi.unlike(likerId: _myId, likedId: profileId);
      } else {
        await LikeApi.like(likerId: _myId, likedId: profileId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (wasLiked) {
          _likedIds = {..._likedIds, profileId};
        } else {
          _likedIds = {..._likedIds}..remove(profileId);
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('like_save_failed'))));
    }
  }

  @override
  void dispose() {
    _hintCtrl.dispose();
    _pageController.dispose();
    _searchDebounce?.cancel();
    _pollTimer?.cancel();
    _swipeHintTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// (Re)arm the idle swipe-hint countdown — called on first load, on every
  /// page change, and on any touch. Hides any visible hint and stops a
  /// running nudge, then fires a fresh one only once the user has sat still
  /// for [_swipeHintDelay].
  void _scheduleSwipeHint() {
    _swipeHintTimer?.cancel();
    _nudging = false;
    _hintCtrl.stop();
    if (_showSwipeHint && mounted) setState(() => _showSwipeHint = false);
    _swipeHintTimer = Timer(_swipeHintDelay, _fireSwipeHint);
  }

  /// Idle nudge: show the up-arrow and peek the next card up (both driven by
  /// [_hintCtrl] so they move together). Re-arms so the nudge repeats every
  /// few seconds until the user moves.
  void _fireSwipeHint() {
    if (!mounted) return;
    setState(() => _showSwipeHint = true);
    _startNudge();
    _swipeHintTimer = Timer(const Duration(seconds: 4), _fireSwipeHint);
  }

  /// Run one peek: forward (card lifts, revealing a sliver of the next card)
  /// then reverse (settles back). [_onHintTick] mirrors [_hintCtrl] onto the
  /// PageController so no gap ever opens. Skipped while the user is dragging.
  void _startNudge() {
    if (!_pageController.hasClients) return;
    final pos = _pageController.position;
    if (pos.isScrollingNotifier.value) return;
    _nudgeStart = pos.pixels;
    _nudging = true;
    _hintCtrl.forward(from: 0).then((_) {
      if (mounted && _nudging) _hintCtrl.reverse();
    });
  }

  /// Mirror [_hintCtrl] onto the page offset so the real next card peeks up
  /// (no mesh gap), kept in lock-step with the arrow that reads the same
  /// controller.
  void _onHintTick() {
    if (!_nudging || !_pageController.hasClients) return;
    final t = Curves.easeOut.transform(_hintCtrl.value);
    _pageController.jumpTo(_nudgeStart + t * _peek);
  }

  /// Any direct touch counts as activity: stop a running nudge and restart
  /// the idle countdown so the hint doesn't fight the user.
  void _onUserActivity() => _scheduleSwipeHint();

  void _expandSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
    });
  }

  void _collapseSearch() {
    _searchDebounce?.cancel();
    _searchFocus.unfocus();
    setState(() {
      _searchExpanded = false;
      _searchCtrl.clear();
      _searchResults = const [];
      _searching = false;
    });
  }

  void _onSearchQueryChanged(String value) {
    // Rebuild so the dropdown's "empty query" / "loading for X" hint
    // reflects the typed text immediately, before the debounced search
    // finishes resolving.
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _runSearch(value),
    );
  }

  Future<void> _runSearch(String value) async {
    final q = value.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchResults = const [];
        _searching = false;
      });
      return;
    }
    if (!isSupabaseReady || _myId.isEmpty) return;
    setState(() => _searching = true);
    try {
      final results = await ProfileApi.searchProfiles(
        query: q,
        myDeviceId: _myId,
      );
      if (!mounted) return;
      setState(() => _searchResults = results);
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchResults = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openSearchResult(RemoteProfile peer) async {
    _collapseSearch();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: peer.id)),
    );
    // Coming back from the profile, the user may have just followed —
    // refresh so pills reflect reality without waiting for the 10s poll.
    if (mounted) _refreshLiveSignals();
  }

  Future<void> _sendFriendRequest(RemoteProfile peer) async {
    final f = await FriendshipApi.sendRequest(meId: _myId, peerId: peer.id);
    if (!mounted) return;
    if (f != null) {
      setState(() => _myFriendships = [..._myFriendships, f]);
    }
    // No confirmation snackbar — adding is silent so swiping through the
    // Discover stack isn't interrupted by a toast on every card.
  }

  FriendshipStatus _statusFor(RemoteProfile peer) {
    final (status, _) = FriendshipApi.statusWith(
      _myId,
      peer.id,
      _myFriendships,
    );
    return status;
  }

  /// Cancel my outgoing friend request to [peer] — delete the pending
  /// friendship row I created. Optimistic local update so the
  /// "Ajouter" pill flips back instantly; rolls back on error.
  Future<void> _cancelFriendRequest(RemoteProfile peer) async {
    final (status, friendship) = FriendshipApi.statusWith(
      _myId,
      peer.id,
      _myFriendships,
    );
    if (status != FriendshipStatus.pendingOutgoing || friendship == null) {
      return;
    }
    final previous = _myFriendships;
    setState(() {
      _myFriendships = _myFriendships
          .where((f) => f.id != friendship.id)
          .toList();
    });
    try {
      await FriendshipApi.remove(friendship.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _myFriendships = previous);
    }
  }

  /// Hand the "Ajouter" pill behaviour over to the parent so a second
  /// tap on a card I've already requested cancels that demande instead
  /// of being a no-op. Status is recomputed from [_myFriendships] each
  /// tap so the toggle stays in sync after refreshes.
  Future<void> _toggleFriendRequest(RemoteProfile peer) async {
    if (_statusFor(peer) == FriendshipStatus.pendingOutgoing) {
      await _cancelFriendRequest(peer);
    } else {
      await _sendFriendRequest(peer);
    }
  }

  /// Toggle a photo reaction on [peer] — send the emoji if I haven't
  /// already, delete every matching reaction message I sent otherwise.
  /// Optimistic local update on both branches so the rail button
  /// flips immediately; rolls back to the cached set on failure.
  Future<void> _toggleEmojiReaction(
    RemoteProfile peer,
    String photo,
    String emoji,
  ) async {
    final wasReacted = _myReactionsByPeer[peer.id]?.contains(emoji) ?? false;
    if (wasReacted) {
      await _unsendEmojiReaction(peer, emoji);
    } else {
      await _sendEmojiReaction(peer, photo, emoji);
    }
  }

  /// Sends a one-character reaction message (the tapped emoji) to [peer].
  /// Reuses the Coucou path so the receiver gets a real chat message
  /// that opens the thread on their side. Tracks the emoji locally so
  /// the rail button stays filled when the card is revisited; the
  /// hydration on bootstrap reads the same set from past messages.
  Future<void> _sendEmojiReaction(
    RemoteProfile peer,
    String photo,
    String emoji,
  ) async {
    // Optimistic local update so the button stays filled immediately
    // without waiting for the round-trip.
    final next = Map<String, Set<String>>.from(_myReactionsByPeer);
    final current = Set<String>.from(next[peer.id] ?? const <String>{});
    current.add(emoji);
    next[peer.id] = current;
    setState(() => _myReactionsByPeer = next);
    await _sendQuickMessage(
      peer,
      body: emoji,
      snack: '$emoji envoyé à ${peer.displayName}',
      discoverPhoto: photo,
    );
  }

  /// Undo a previously-sent reaction. Pulls the emoji out of the local
  /// set, then deletes every matching message I sent so the peer's
  /// thread / Demandes feed loses the entry too.
  Future<void> _unsendEmojiReaction(RemoteProfile peer, String emoji) async {
    final previous = _myReactionsByPeer;
    final next = Map<String, Set<String>>.from(previous);
    final current = Set<String>.from(next[peer.id] ?? const <String>{});
    current.remove(emoji);
    if (current.isEmpty) {
      next.remove(peer.id);
    } else {
      next[peer.id] = current;
    }
    setState(() => _myReactionsByPeer = next);
    try {
      await ChatApi.deleteMyReaction(
        meId: _myId,
        peerId: peer.id,
        emoji: emoji,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _myReactionsByPeer = previous);
    }
  }

  /// Drop [body] into the deterministic dm-{a}-{b} thread for the local
  /// user and [peer], same conversation id the chat list uses. Shared by
  /// the "Ajouter" 👋 pill and the reaction-rail emoji taps.
  Future<void> _sendQuickMessage(
    RemoteProfile peer, {
    required String body,
    required String snack,
    String discoverPhoto = '',
  }) async {
    if (_myId.isEmpty || peer.id.isEmpty) return;
    try {
      final local = await UserPrefs.loadProfile();
      final myProfile = isSupabaseReady
          ? await ProfileApi.fetchById(_myId)
          : null;
      final myName = (myProfile?.displayName.trim().isNotEmpty == true)
          ? myProfile!.displayName
          : (local?.firstName.trim() ?? '');
      final myLang = (myProfile?.language.trim().isNotEmpty == true)
          ? myProfile!.language
          : (local?.sourceLang ?? '');
      final ids = [_myId, peer.id]..sort();
      final convId = 'dm-${ids[0]}-${ids[1]}';
      await ChatApi.sendMessage(
        conversationId: convId,
        senderId: _myId,
        senderName: myName,
        recipientId: peer.id,
        body: body,
        language: myLang,
        discoverPhoto: discoverPhoto,
      );
      if (!mounted) return;
      _showAddedSnack(snack);
    } catch (e) {
      if (!mounted) return;
      _showAddedSnack('Envoi échoué : $e', isError: true);
    }
  }

  /// Send a one-off intro message to [peer] from the Discover card text area,
  /// stamped with the card's [photoUrl]. One per photo: optimistically marks
  /// the photo as messaged (the in-card field collapses to a sent state) and
  /// persists via the real chat message — [ChatApi.sendMessage] also fires the
  /// push notification to the peer.
  Future<void> _sendDirectMessage(
    RemoteProfile peer,
    String photoUrl,
    String text,
  ) async {
    final body = text.trim();
    if (body.isEmpty || _myId.isEmpty || peer.id.isEmpty) return;
    if (_directMessagedPhotos.contains(photoUrl)) return;
    setState(() => _directMessagedPhotos = {..._directMessagedPhotos, photoUrl});
    await _sendQuickMessage(
      peer,
      body: body,
      snack: 'Message envoyé à ${peer.displayName}',
      discoverPhoto: photoUrl,
    );
  }

  /// Floating glass snackbar lifted above the floating GlassNavBar so
  /// the message isn't hidden by it. Same Swayco Midnight palette as
  /// the cards.
  void _showAddedSnack(String text, {bool isError = false}) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    // The nav is now flush to the bottom: its height + the safe-area inset.
    // Lift the snack ~16 px above that so the two never overlap.
    final liftFromBottom = GlassNavBar.height + safeBottom + 16.0;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            text,
            style: const TextStyle(
              color: SC.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: isError ? const Color(0xFF4A1A22) : SC.bubbleIn,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: const BorderSide(color: SC.glassBorder),
          ),
          margin: EdgeInsets.fromLTRB(24, 0, 24, liftFromBottom),
        ),
      );
  }

  Future<void> _reset() async {
    if (_pageController.hasClients) _pageController.jumpToPage(0);
    if (_myId.isEmpty) return;
    setState(() => _feedLoading = true);
    final feed = await ProfileApi.fetchDiscoverFeed(myId: _myId);
    if (!mounted) return;
    setState(() {
      _profiles = feed;
      _rebuildCards();
      _feedLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    // The card deck sits strictly between the two bars' bodies. The bars
    // then grow over these edges with concave notches (see GlassNavBar /
    // _DiscoverHeader) that hug the card's rounded corners, no gap.
    final deckTop = safeTop + _DiscoverHeader.height;
    final deckBottom = GlassNavBar.height + safeBottom;
    return Scaffold(
      backgroundColor: SC.bg,
      // Cards extend behind the floating nav bar (rendered by RootShell).
      extendBody: true,
      body: MeshBackground(
        child: Stack(
          children: [
            // The card deck, inset to the gap between the two bar bodies.
            // Each page is exactly the gap height, so cards slide in flush.
            // When the user lingers, _fireSwipeHint peeks the next card up
            // through the PageController to demo the swipe.
            Positioned(
              left: 0,
              right: 0,
              top: deckTop,
              bottom: deckBottom,
              child: _feedLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: SC.accent),
                    )
                  : _buildStack(),
            ),
            // Full-width frosted-glass top bar — mirrors the bottom nav so
            // the full-bleed photo runs behind both with no empty strip at
            // the top. The bar bakes in the safe-area inset itself.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _DiscoverHeader(
                expanded: _searchExpanded,
                controller: _searchCtrl,
                focusNode: _searchFocus,
                onTapPill: _expandSearch,
                onSubmittedClose: _collapseSearch,
                onChanged: _onSearchQueryChanged,
              ),
            ),
            // Tap-outside scrim to dismiss the search.
            if (_searchExpanded)
              Positioned.fill(
                top: safeTop + 64,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _collapseSearch,
                  child: const ColoredBox(color: Color(0x88000000)),
                ),
              ),
            // Search results dropdown — overlays the cards.
            if (_searchExpanded)
              Positioned(
                left: 16,
                right: 16,
                top: safeTop + 60,
                child: _SearchResultsPanel(
                  loading: _searching,
                  query: _searchCtrl.text.trim(),
                  results: _searchResults,
                  statusFor: _statusFor,
                  onAdd: _sendFriendRequest,
                  onOpen: _openSearchResult,
                ),
              ),
            // Swipe-up arrow hint removed on request. The subtle card "peek"
            // nudge (driven by [_hintCtrl]) still rides on [_showSwipeHint].
            if (_showSwipeHint && _cards.length > 1 && !_searchExpanded)
              const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  Widget _buildStack() {
    // Each PageView page renders one profile card sized at 3:4 portrait,
    // capped at 460 wide on desktop so the photo isn't stretched into
    // the full width of a 1900-px viewport. PageView handles the
    // vertical snap + slide animation natively — swipe up reveals the
    // next profile, swipe down brings the previous one back.
    //
    // We add one extra page after the last profile: the "all caught up"
    // empty state, so the user can scroll into it the same way they
    // scroll between profiles.
    return Listener(
      // Any touch on the deck is activity — stop a running hint nudge and
      // restart the idle countdown so we never fight the user's gesture.
      onPointerDown: (_) => _onUserActivity(),
      // On desktop a trackpad/mouse-wheel scroll can deliver enough
      // delta to skip several pages before the snap kicks in. We
      // intercept wheel ticks here and advance/rewind the PageView
      // by exactly one page, debounced so trackpad streams don't
      // burn through profiles.
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        final dy = event.scrollDelta.dy;
        if (dy.abs() < 4) return;
        final now = DateTime.now();
        if (now.difference(_lastWheel) < const Duration(milliseconds: 220)) {
          return;
        }
        _lastWheel = now;
        if (dy > 0) {
          _pageController.nextPage(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        } else {
          _pageController.previousPage(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        }
      },
      child: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        // Snappier than the default page physics — a quick flick lands on
        // the next card in ~half the usual time. ClampingScrollPhysics as
        // the parent so we don't get the iOS bouncing overscroll, which
        // was opening a visible gap above the first card / below the
        // last one. On desktop the parent Listener also rate-limits
        // wheel scrolling above this physics.
        physics: const _SnappyPagePhysics(parent: ClampingScrollPhysics()),
        // Reset the idle swipe-hint timer every time a new profile lands.
        onPageChanged: (_) => _scheduleSwipeHint(),
        // Unbounded itemCount + modulo on the index = the feed loops
        // forever: after the last profile the user lands back on the
        // first one (1 → 2 → 3 → 1 → 2 → 3 …).
        itemBuilder: (ctx, i) {
          if (_cards.isEmpty) {
            return _Empty(onReset: _reset);
          }
          // Dart's `%` returns a non-negative result for a positive
          // divisor, so this also wraps cleanly when the user swipes
          // backward past the first card. One card == one photo.
          final card = _cards[i % _cards.length];
          final profile = card.profile;
          // The deck is already inset between the two bars (see build), so
          // the card just fills its page — that keeps consecutive cards
          // contiguous, sliding in flush with no gap between them.
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SizedBox.expand(
                child: _ProfileCard(
                  profile: profile,
                  photoUrl: card.photo,
                  onAdd: () => _toggleFriendRequest(profile),
                  pendingOutgoing:
                      _statusFor(profile) == FriendshipStatus.pendingOutgoing,
                  liked: _likedIds.contains(profile.id),
                  onToggleLike: () => _toggleLikeOnProfile(profile.id),
                  onSendEmoji: (emoji) =>
                      _toggleEmojiReaction(profile, card.photo, emoji),
                  reactedEmojis:
                      _myReactionsByPeer[profile.id] ?? const <String>{},
                  alreadyMessaged: _directMessagedPhotos.contains(card.photo),
                  onSendMessage: (text) =>
                      _sendDirectMessage(profile, card.photo, text),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DiscoverHeader extends StatelessWidget {
  const _DiscoverHeader({
    required this.expanded,
    required this.controller,
    required this.focusNode,
    required this.onTapPill,
    required this.onChanged,
    required this.onSubmittedClose,
  });

  final bool expanded;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onTapPill;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmittedClose;

  /// Height of the bar's content row (below the safe-area inset, which the
  /// bar pads itself). Exposed so the Discover card can reserve exactly
  /// this much space at the top and sit flush against the bar's edge.
  static const double height = 60;

  @override
  Widget build(BuildContext context) {
    // Pad the bar's own top by the system safe-area inset so the glass
    // fills up to the screen edge (behind the notch / status bar) while
    // the title + search pill stay below it.
    final topInset = MediaQuery.paddingOf(context).top;
    return ClipPath(
      // Concave notches at the two bottom corners — the bar grows down by
      // hugRadius at the edges and curves in, wrapping snugly around the
      // rounded top corners of the Discover card below it (no gap).
      clipper: const _BottomHugClipper(GlassNavBar.hugRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          color: Colors.white.withValues(alpha: 0.12),
          // Bottom pad by the notch strip so the title / search stay in the
          // body above the corner notches; top pad by the safe-area inset.
          padding: EdgeInsets.only(
            top: topInset,
            bottom: GlassNavBar.hugRadius,
          ),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(AppStrings.t('discover_title'), style: SCText.h1),
                  const Spacer(),
                  // Search pill: compact button when collapsed, wider TextField
                  // when expanded — but never full-width.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    width: expanded ? 200 : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: SC.glassStrong,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: SC.glassBorder),
                    ),
                    child: Row(
                      mainAxisSize: expanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      children: [
                        const Icon(Icons.search, size: 16, color: SC.textMuted),
                        const SizedBox(width: 6),
                        if (expanded)
                          Expanded(
                            // Local TextSelectionTheme so the selection halo /
                            // handles match the Midnight cyan instead of the
                            // legacy WhatsApp-green accent inherited from the
                            // global theme.
                            child: TextSelectionTheme(
                              data: TextSelectionThemeData(
                                cursorColor: SC.accent,
                                selectionColor: SC.accent.withValues(
                                  alpha: 0.35,
                                ),
                                selectionHandleColor: SC.accent,
                              ),
                              child: TextField(
                                controller: controller,
                                focusNode: focusNode,
                                onChanged: onChanged,
                                textInputAction: TextInputAction.search,
                                cursorColor: SC.accent,
                                style: const TextStyle(
                                  color: SC.textPrimary,
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: AppStrings.t('search_friend_hint'),
                                  hintStyle: const TextStyle(
                                    color: SC.textMuted,
                                    fontSize: 13,
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onTapPill,
                            child: Text(
                              AppStrings.t('search_chercher'),
                              style: const TextStyle(
                                color: SC.textMuted,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        if (expanded)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onSubmittedClose,
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: SC.textMuted,
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
    );
  }
}

/// Mirror of GlassNavBar's top-corner clipper: a full-width rectangle whose
/// two BOTTOM corners are carved out by a concave notch of [radius], so the
/// top bar wraps the rounded top corners of the Discover card below it.
class _BottomHugClipper extends CustomClipper<Path> {
  const _BottomHugClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) {
    final r = radius;
    final w = size.width;
    final h = size.height;
    final leftNotch = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTRB(0, h - r, r, h)),
      Path()..addOval(Rect.fromCircle(center: Offset(r, h), radius: r)),
    );
    final rightNotch = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTRB(w - r, h - r, w, h)),
      Path()..addOval(Rect.fromCircle(center: Offset(w - r, h), radius: r)),
    );
    var path = Path()..addRect(Rect.fromLTRB(0, 0, w, h - r));
    path = Path.combine(PathOperation.union, path, leftNotch);
    path = Path.combine(PathOperation.union, path, rightNotch);
    return path;
  }

  @override
  bool shouldReclip(_BottomHugClipper oldClipper) =>
      oldClipper.radius != radius;
}

class _SearchResultsPanel extends StatelessWidget {
  const _SearchResultsPanel({
    required this.loading,
    required this.query,
    required this.results,
    required this.statusFor,
    required this.onAdd,
    required this.onOpen,
  });

  final bool loading;
  final String query;
  final List<RemoteProfile> results;
  final FriendshipStatus Function(RemoteProfile) statusFor;
  final ValueChanged<RemoteProfile> onAdd;
  final ValueChanged<RemoteProfile> onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.bubbleIn,
      borderRadius: BorderRadius.circular(16),
      elevation: 8,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (query.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          AppStrings.t('search_intro_hint'),
          style: const TextStyle(color: SC.textMuted, fontSize: 13),
        ),
      );
    }
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              color: SC.accent,
              strokeWidth: 2.4,
            ),
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Aucun profil pour « $query ».',
          style: const TextStyle(color: SC.textMuted, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: results.length,
      separatorBuilder: (_, _) =>
          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
      itemBuilder: (_, i) {
        final p = results[i];
        return _SearchResultRow(
          profile: p,
          status: statusFor(p),
          onAdd: () => onAdd(p),
          onTap: () => onOpen(p),
        );
      },
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({
    required this.profile,
    required this.status,
    required this.onAdd,
    required this.onTap,
  });

  final RemoteProfile profile;
  final FriendshipStatus status;
  final VoidCallback onAdd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            ProfileAvatar(
              displayName: profile.displayName,
              avatarUrl: profile.avatarUrl,
              avatarColorHex: profile.avatarColor,
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
                      color: SC.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (profile.handle.isNotEmpty)
                    Text(
                      '@${profile.handle}',
                      style: const TextStyle(color: SC.textMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
            _statusButton(),
          ],
        ),
      ),
    );
  }

  Widget _statusButton() {
    switch (status) {
      case FriendshipStatus.accepted:
        return _StatusPill(
          label: AppStrings.t('friendship_friend'),
          color: SC.accent,
        );
      case FriendshipStatus.pendingOutgoing:
        return _StatusPill(
          label: AppStrings.t('friendship_sent'),
          color: Colors.amber,
        );
      case FriendshipStatus.pendingIncoming:
        return _StatusPill(
          label: AppStrings.t('friendship_pending_in'),
          color: Colors.amber,
        );
      case FriendshipStatus.rejected:
      case FriendshipStatus.none:
        return Material(
          color: SC.accent,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Text(
                // Reuses the search-result "Ajouter" button label —
                // localised via the friendship_sent / etc. keys' sibling.
                AppStrings.t('add_friend_short'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
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

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.photoUrl,
    required this.onAdd,
    this.pendingOutgoing = false,
    this.liked = false,
    this.onToggleLike,
    this.onSendEmoji,
    this.reactedEmojis = const <String>{},
    this.alreadyMessaged = false,
    this.onSendMessage,
  });

  final RemoteProfile profile;

  /// The single photo this card shows. The Discover feed is one card per
  /// photo, so each of a profile's gallery photos gets its own card.
  final String photoUrl;

  final VoidCallback onAdd;

  /// True when I already have a pending outgoing friend request to
  /// [profile]. Drives the "Ajouter" pill into its "Envoyé" state;
  /// re-tapping then cancels the request via [onAdd].
  final bool pendingOutgoing;
  final bool liked;

  /// When non-null, a heart button is rendered to the right of "Envoyer 👋".
  /// Tap toggles liked state.
  final VoidCallback? onToggleLike;

  /// Fires with the emoji string when one of the reaction-rail buttons
  /// is tapped — sends that emoji as a chat message to [profile].
  final ValueChanged<String>? onSendEmoji;

  /// Emojis I've already sent to [profile] — each matching button on
  /// the rail renders pre-filled.
  final Set<String> reactedEmojis;

  /// True when I've already sent [profile] a direct intro message — the
  /// in-card text field is replaced by a "message sent" state (one per peer).
  final bool alreadyMessaged;

  /// Send a one-off intro message to [profile] from the in-card text area.
  /// Null on non-interactive (background-deck) cards.
  final Future<void> Function(String)? onSendMessage;

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(profile.language);
    final flag = lang?.flag ?? '';
    // "Ville, Pays" shown small under the name (either part may be empty).
    final locationLabel = [profile.city.trim(), profile.country.trim()]
        .where((s) => s.isNotEmpty)
        .join(', ');
    return DecoratedBox(
      decoration: BoxDecoration(
        // Match the bars' notch radius so the card's rounded corners nest
        // exactly into the concave notches of the top bar / nav.
        borderRadius: BorderRadius.circular(GlassNavBar.hugRadius),
        boxShadow: [
          BoxShadow(
            color: SC.meshCyan.withValues(alpha: 0.30),
            blurRadius: 60,
            offset: const Offset(0, 30),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassNavBar.hugRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: SC.bubbleIn),
            if (photoUrl.isNotEmpty)
              Image.network(
                photoUrl,
                fit: BoxFit.cover,
                // Centre crop — keeps the subject roughly in the middle of
                // the card whatever the source aspect ratio.
                alignment: Alignment.center,
                errorBuilder: (_, _, _) => const ColoredBox(color: SC.bubbleIn),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.10),
                      Colors.black.withValues(alpha: 0.85),
                    ],
                    stops: const [0.45, 0.65, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 22,
              right: 22,
              bottom: 22,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Left side: name + flag + bio + send button stacked vertically.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Name + flag.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Flexible(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          ProfileScreen(userId: profile.id),
                                    ),
                                  );
                                },
                                child: Text(
                                  profile.displayName.isEmpty
                                      ? '—'
                                      : profile.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: SCText.h1.copyWith(
                                    fontSize: 32,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            if (flag.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  flag,
                                  style: const TextStyle(fontSize: 22),
                                ),
                              ),
                            ],
                          ],
                        ),
                        // Location (ville, pays) — small, just under the name.
                        if (locationLabel.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.place_outlined,
                                size: 14,
                                color: Colors.white.withValues(alpha: 0.8),
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  locationLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        // Bio under the name line.
                        if (profile.bio.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            profile.bio,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        _AddButton(onTap: onAdd, sent: pendingOutgoing),
                        // Direct intro message — one per person. Hidden on
                        // background-deck cards (onSendMessage null).
                        if (onSendMessage != null) ...[
                          const SizedBox(height: 10),
                          if (alreadyMessaged)
                            const _MessageSentPill()
                          else
                            _DirectMessageField(
                              onSend: onSendMessage!,
                            ),
                        ],
                      ],
                    ),
                  ),
                  // Right rail: reaction emojis (ghosted until tapped).
                  // Skipped for background-deck instances where interaction
                  // is off.
                  if (onSendEmoji != null) ...[
                    const SizedBox(width: 12),
                    _ReactionRail(
                      onSendEmoji: onSendEmoji,
                      reactedEmojis: reactedEmojis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vertical reaction rail rendered on the right side of a profile card —
/// ghosted "send-a-vibe" emojis, each dim by default and filled when tapped.
class _ReactionRail extends StatelessWidget {
  const _ReactionRail({
    this.onSendEmoji,
    this.reactedEmojis = const <String>{},
  });

  /// Fires with the tapped emoji string — handed to each
  /// [_ReactionEmojiButton]. Wired by the parent card to drop the emoji
  /// into the peer's DM thread, same behaviour as the legacy 👋 Coucou.
  final ValueChanged<String>? onSendEmoji;

  /// Emojis the local user has already sent to this peer — each
  /// matching button renders pre-filled so the rail survives refreshes.
  final Set<String> reactedEmojis;

  // Fixed across all cards so users learn the rail by muscle memory.
  static const _emojis = <String>['🔥', '✨', '😍'];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _emojis.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _ReactionEmojiButton(
            emoji: _emojis[i],
            reacted: reactedEmojis.contains(_emojis[i]),
            onSend:
                onSendEmoji == null ? null : () => onSendEmoji!(_emojis[i]),
          ),
        ],
      ],
    );
  }
}

/// One reaction-rail emoji — mirrors [_LikeHeart] exactly so the rail
/// feels uniform with the heart at its bottom: same 48 px circle, same
/// dark glass chip when idle, same accented border when active, same
/// 160 ms animation. State is local — refreshes when the parent card
/// rebuilds (e.g. after swiping to a new profile).
/// One reaction-rail button. State is fully driven by [reacted] —
/// the parent card hydrates the persisted set from past messages and
/// updates it optimistically when [onSend] fires, so the fill survives
/// refreshes and revisits.
class _ReactionEmojiButton extends StatelessWidget {
  const _ReactionEmojiButton({
    required this.emoji,
    required this.reacted,
    this.onSend,
  });

  final String emoji;

  /// True when the local user has already sent this emoji to the peer.
  /// Drives the filled / unfilled visuals; no local state.
  final bool reacted;

  /// Fires when the user taps the button. The rail wires this to a
  /// toggle on the parent — first tap drops the emoji into the peer's
  /// DM thread, a second tap deletes it. Visuals are driven by
  /// [reacted] so the button reflects the persisted state after the
  /// parent's optimistic update lands.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    // Builder so the [GestureDetector] gets its own BuildContext
    // whose RenderObject is the actual button — we resolve its global
    // position from there to anchor the emoji burst.
    return Builder(
      builder: (ctx) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSend == null
              ? null
              : () {
                  // Spawn a particle burst only on the send branch
                  // (reacted=false now → about to flip to true). The
                  // unsend branch fires without the celebration so the
                  // gesture stays calm.
                  if (!reacted) {
                    final box = ctx.findRenderObject() as RenderBox?;
                    if (box != null && box.hasSize) {
                      final pos = box.localToGlobal(
                        box.size.center(Offset.zero),
                      );
                      EmojiBurst.show(ctx, position: pos, emoji: emoji);
                    }
                  }
                  onSend!();
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: reacted
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: 0.35),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: reacted ? 0.85 : 0.20),
                width: reacted ? 2 : 1,
              ),
            ),
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 160),
                // Keep the emojis at full opacity in both states —
                // the background fill + bigger glyph still signal
                // "this one is sent", but the un-tapped emojis stop
                // reading as ghosted / disabled. Drop shadow lifts
                // each glyph off the chip for a subtle 3D feel.
                style: TextStyle(
                  fontSize: reacted ? 24 : 22,
                  color: Colors.white,
                  shadows: const [
                    Shadow(
                      color: Color(0x66000000),
                      blurRadius: 6,
                      offset: Offset(0, 3),
                    ),
                    Shadow(
                      color: Color(0x99000000),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                child: Text(emoji),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// In-card direct-message field on the Discover card — type a one-off intro
/// message and send it. One per person: after sending, the parent flips the
/// card to [_MessageSentPill]. Translucent dark pill with white text so it
/// reads over the photo.
class _DirectMessageField extends StatefulWidget {
  const _DirectMessageField({required this.onSend});
  final Future<void> Function(String) onSend;
  @override
  State<_DirectMessageField> createState() => _DirectMessageFieldState();
}

class _DirectMessageFieldState extends State<_DirectMessageField> {
  final TextEditingController _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Rebuild on text changes so the send arrow only shows while typing.
    _ctrl.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    await widget.onSend(text);
    // The parent rebuilds this card into _MessageSentPill once the photo is
    // marked messaged; guard mounted in case it already swapped out.
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return ConstrainedBox(
      // Smaller, doesn't span the whole card width.
      constraints: const BoxConstraints(maxWidth: 250),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        padding: EdgeInsets.fromLTRB(14, 0, hasText ? 4 : 14, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: TextField(
                controller: _ctrl,
                enabled: !_sending,
                minLines: 1,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                cursorColor: SC.accent,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: AppStrings.t('discover_message_hint'),
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13.5,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            // Send arrow only appears once there's something to send.
            if (hasText)
              GestureDetector(
                onTap: _sending ? null : _send,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child:
                      Icon(Icons.send_rounded, color: SC.accent, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown in place of [_DirectMessageField] once the intro message was sent.
class _MessageSentPill extends StatelessWidget {
  const _MessageSentPill();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            AppStrings.t('discover_message_sent'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Ajouter" pill — sends a friend-request-style action on tap, then
/// flips its label to "Envoyé" and stops being tappable. Light haptic
/// on the first press; the label transition cross-fades smoothly.
/// "Ajouter" pill on the Discover deck. Drives a friend-request
/// toggle: first tap sends, a tap when already pending cancels.
/// State is owned by the parent card so the pill survives card
/// rebuilds (e.g. swiping back) and reflects the live friendship
/// table on every refresh.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap, required this.sent});
  final VoidCallback onTap;

  /// True when I have a pending outgoing friend request to this peer
  /// — flips the label to "Envoyé" and still fires [onTap] on press
  /// so the parent can cancel the demande.
  final bool sent;

  void _handleTap() {
    HapticFeedback.mediumImpact();
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _handleTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              sent ? AppStrings.t('sent_label') : AppStrings.t('profile_add'),
              key: ValueKey(sent),
              style: const TextStyle(
                color: SC.bg,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Page-snap physics with a stiffer spring than Flutter's default, so
/// a vertical flick lands on the next card faster. Critically damped
/// (damping ≈ 2·√(mass·stiffness)) so the spring never oscillates
/// past the target page. The fling velocity itself is also clamped
/// so a very fast flick still settles on the very next card instead
/// of zooming through several before the spring catches it.
class _SnappyPagePhysics extends PageScrollPhysics {
  const _SnappyPagePhysics({super.parent});

  @override
  _SnappyPagePhysics applyTo(ScrollPhysics? ancestor) {
    return _SnappyPagePhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => const SpringDescription(
    mass: 0.5,
    stiffness: 220,
    // 2 · √(0.5 · 220) ≈ 21 → critically damped, no overshoot.
    damping: 22,
  );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // Cap the launch velocity passed to the snap spring so a hard
    // flick can't carry the offset visually past the next page
    // before the spring pulls it back. PageScrollPhysics already
    // limits the *target* to ±1 page; this controls the *path*.
    final clamped = velocity.clamp(-900.0, 900.0);
    return super.createBallisticSimulation(position, clamped);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onReset});
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: SC.bubbleIn,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.favorite_border,
                color: SC.textMuted,
                size: 34,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('discover_done'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
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
