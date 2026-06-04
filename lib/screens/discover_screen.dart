import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/app_boot.dart';
import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
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

  // The feed is one card per PERSON: each profile's photos (newest first,
  // capped at 6) are shown as a horizontal carousel inside their single card.
  // Rebuilt whenever [_profiles] changes.
  static const int _maxCardPhotos = 6;
  final List<({RemoteProfile profile, List<String> photos})> _cards = [];

  void _rebuildCards() {
    _cards.clear();
    for (final p in _profiles) {
      final photos = p.photos.where((u) => u.isNotEmpty).toList();
      List<String> shown;
      if (photos.isEmpty) {
        // Legacy rows with no gallery: fall back to the single photo.
        final single = p.discoverPhotoUrl.isNotEmpty
            ? p.discoverPhotoUrl
            : p.avatarUrl;
        shown = single.isNotEmpty ? <String>[single] : const <String>[];
      } else {
        // Newest photos sit at the end of the array (append-on-upload), so
        // reverse to show the most recent first; cap the carousel at 6.
        shown = photos.reversed.take(_maxCardPhotos).toList();
      }
      if (shown.isNotEmpty) _cards.add((profile: p, photos: shown));
    }
  }

  // photo URL → set of photo-reaction emojis I've already sent on that photo.
  // Reactions belong to a specific photo now, so the rail renders pre-filled
  // only for the exact carousel photo I reacted to. Hydrated from the
  // messages table on bootstrap so it survives restarts / multi-device.
  Map<String, Set<String>> _myReactionsByPhoto = const {};

  // Peers I've already sent a direct intro message to (text area). One message
  // per PERSON (each card is one person now), hydrated on bootstrap so it
  // survives restarts; the in-card field collapses to a sent state once the
  // peer is here.
  Set<String> _directMessagedPeers = <String>{};

  // TikTok-style vertical pager. Swipe up = next profile, swipe down =
  // previous. Snapping + the slide animation are handled by PageView.
  // Not final: at bootstrap we swap it for one with the right initialPage so
  // the deck resumes on the card we left off (see _restoreCursor).
  PageController _pageController = PageController();

  // Raw PageView index of the card currently on top. Persisted (as that
  // person's profile id, via _persistCursor) on every page change so a
  // restart resumes here instead of snapping back to the first card.
  int _topIndex = 0;

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
  // the next card up (driven by [_hintCtrl], no rebuild). Any swipe / touch
  // resets it.
  Timer? _swipeHintTimer;
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
      final reactions = await ChatApi.fetchMyOutgoingPhotoReactions(_myId);
      final messaged = await ChatApi.fetchMyDiscoverMessagedPeers(_myId);
      if (!mounted) return;
      setState(() {
        _myFriendships = mine;
        _myReactionsByPhoto = reactions;
        _directMessagedPeers = messaged;
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
      AppBoot.markHomeReady();
      return;
    }
    try {
      // These six queries are independent — fire them concurrently (was
      // sequential: six round-trips back-to-back, the main reason the deck
      // sat on its spinner for seconds). Bounded so a slow / wedged call
      // can't trap the spinner forever; on timeout we drop into the catch
      // and show the deck rather than spin indefinitely.
      final results = await Future.wait(<Future<Object>>[
        FriendshipApi.fetchMine(id),
        ChatApi.fetchMyOutgoingPhotoReactions(id),
        ChatApi.fetchMyDiscoverMessagedPeers(id),
        ProfileApi.fetchDiscoverFeed(myId: id),
        UserPrefs.loadDiscoverCursor(),
      ]).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _myFriendships = results[0] as List<Friendship>;
        _myReactionsByPhoto = results[1] as Map<String, Set<String>>;
        _directMessagedPeers = results[2] as Set<String>;
        _profiles = results[3] as List<RemoteProfile>;
        _rebuildCards();
        _restoreCursor(results[4] as String);
        _feedLoading = false;
      });
      AppBoot.markHomeReady();
    } catch (_) {
      if (mounted) setState(() => _feedLoading = false);
      AppBoot.markHomeReady();
    }
  }

  /// Resume the deck on the card we were parked on last session. Called from
  /// the bootstrap setState, while we're still _feedLoading — so the PageView
  /// isn't built yet and the controller has no clients. Swapping it for one
  /// with the right initialPage lands us on that person with no visible jump
  /// to the first card. We match by profile id (not the saved index) so it
  /// holds up even if the feed comes back reordered.
  void _restoreCursor(String cursorId) {
    if (cursorId.isEmpty || _cards.isEmpty) return;
    final idx = _cards.indexWhere((c) => c.profile.id == cursorId);
    if (idx <= 0) return; // not found, or already the first card
    _pageController.dispose();
    _pageController = PageController(initialPage: idx);
    _topIndex = idx;
  }

  /// Remember which person is on top so a restart resumes here. Fire-and-forget
  /// write on every page change; we store the profile id, not the raw index.
  void _persistCursor() {
    if (_cards.isEmpty) return;
    UserPrefs.saveDiscoverCursor(_cards[_topIndex % _cards.length].profile.id);
  }

  /// Toggle a like on [profileId]. Optimistic local flip + DB write
  /// through LikeApi; on error roll back so the heart matches the truth.

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
    _swipeHintTimer = Timer(_swipeHintDelay, _fireSwipeHint);
  }

  /// Idle nudge: peek the next card up (driven by [_hintCtrl] via
  /// [_onHintTick] — no setState, so the deck/images never rebuild or blink).
  /// Re-arms so the nudge repeats every few seconds until the user moves.
  void _fireSwipeHint() {
    if (!mounted) return;
    if (_cards.length > 1 && !_searchExpanded) _startNudge();
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
    if (photo.isEmpty) return;
    final wasReacted = _myReactionsByPhoto[photo]?.contains(emoji) ?? false;
    if (wasReacted) {
      await _unsendEmojiReaction(peer, photo, emoji);
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
    // Optimistic local update (keyed by the photo) so the button stays
    // filled immediately without waiting for the round-trip.
    final next = Map<String, Set<String>>.from(_myReactionsByPhoto);
    final current = Set<String>.from(next[photo] ?? const <String>{});
    current.add(emoji);
    next[photo] = current;
    setState(() => _myReactionsByPhoto = next);
    // Stamp the photo URL into discover_photo so the reaction belongs to THIS
    // photo (intro messages are told apart by their non-emoji body, so this
    // doesn't collapse the card's message field).
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
  Future<void> _unsendEmojiReaction(
    RemoteProfile peer,
    String photo,
    String emoji,
  ) async {
    final previous = _myReactionsByPhoto;
    final next = Map<String, Set<String>>.from(previous);
    final current = Set<String>.from(next[photo] ?? const <String>{});
    current.remove(emoji);
    if (current.isEmpty) {
      next.remove(photo);
    } else {
      next[photo] = current;
    }
    setState(() => _myReactionsByPhoto = next);
    try {
      await ChatApi.deleteMyReaction(
        meId: _myId,
        peerId: peer.id,
        emoji: emoji,
        photoUrl: photo,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _myReactionsByPhoto = previous);
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

  /// Send a one-off intro message to [peer] from the Discover card text area.
  /// One per PERSON: optimistically marks the peer as messaged (the in-card
  /// field collapses to a sent state) and persists via the real chat message —
  /// [ChatApi.sendMessage] also fires the push notification to the peer. The
  /// [photoUrl] is stamped on the message purely to flag it as a Discover
  /// intro (so it counts towards the per-person hydration).
  Future<void> _sendDirectMessage(
    RemoteProfile peer,
    String photoUrl,
    String text,
  ) async {
    final body = text.trim();
    if (body.isEmpty || _myId.isEmpty || peer.id.isEmpty) return;
    if (_directMessagedPeers.contains(peer.id)) return;
    setState(() => _directMessagedPeers = {..._directMessagedPeers, peer.id});
    await _sendQuickMessage(
      peer,
      body: body,
      snack: 'Message envoyé à ${peer.displayName}',
      discoverPhoto: photoUrl.isEmpty ? peer.id : photoUrl,
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
            // Cyan-blue ambient wash over the mesh: turns the fond behind the
            // card from flat navy into a cyan-blue glow — brightest right
            // behind the card, fading to a cyan-navy cast at the edges.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.2,
                    colors: [
                      SC.meshCyan.withValues(alpha: 0.50),
                      SC.meshBlue.withValues(alpha: 0.30),
                      SC.meshNavy.withValues(alpha: 0.22),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
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
                  // Tap anywhere on the deck that isn't the message field or a
                  // button dismisses the keyboard. translucent so taps on the
                  // empty photo area still register here; the TextField / the
                  // action buttons win the gesture arena first, and onTap never
                  // claims the vertical drag the PageView uses to swipe cards.
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => FocusScope.of(context).unfocus(),
                      child: _buildStack(),
                    ),
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
        // Remember the new top card (so a restart resumes here) and reset
        // the idle swipe-hint timer every time a new profile lands.
        onPageChanged: (i) {
          _topIndex = i;
          _persistCursor();
          _scheduleSwipeHint();
        },
        // Unbounded itemCount + modulo on the index = the feed loops
        // forever: after the last profile the user lands back on the
        // first one (1 → 2 → 3 → 1 → 2 → 3 …).
        itemBuilder: (ctx, i) {
          if (_cards.isEmpty) {
            return _Empty(onReset: _reset);
          }
          // Dart's `%` returns a non-negative result for a positive
          // divisor, so this also wraps cleanly when the user swipes
          // backward past the first card. One card == one person.
          final card = _cards[i % _cards.length];
          final profile = card.profile;
          final firstPhoto = card.photos.isNotEmpty ? card.photos.first : '';
          // The deck is already inset between the two bars (see build), so
          // the card just fills its page — that keeps consecutive cards
          // contiguous, sliding in flush with no gap between them.
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SizedBox.expand(
                // Keyed by person so each card keeps its own carousel index
                // as the deck recycles pages.
                child: _ProfileCard(
                  key: ValueKey(profile.id),
                  profile: profile,
                  photos: card.photos,
                  onAdd: () => _toggleFriendRequest(profile),
                  pendingOutgoing:
                      _statusFor(profile) == FriendshipStatus.pendingOutgoing,
                  // Reactions belong to the photo currently shown in the
                  // carousel — the card resolves it and calls back with it.
                  reactionsByPhoto: _myReactionsByPhoto,
                  onSendEmoji: (photo, emoji) =>
                      _toggleEmojiReaction(profile, photo, emoji),
                  alreadyMessaged: _directMessagedPeers.contains(profile.id),
                  onSendMessage: (text) =>
                      _sendDirectMessage(profile, firstPhoto, text),
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

class _ProfileCard extends StatefulWidget {
  const _ProfileCard({
    super.key,
    required this.profile,
    required this.photos,
    required this.onAdd,
    this.pendingOutgoing = false,
    this.onSendEmoji,
    this.reactionsByPhoto = const {},
    this.alreadyMessaged = false,
    this.onSendMessage,
  });

  final RemoteProfile profile;

  /// This person's photos (newest first, max 6) shown as a horizontal
  /// carousel inside the card. The Discover feed is one card per person.
  final List<String> photos;

  final VoidCallback onAdd;

  /// True when I already have a pending outgoing friend request to
  /// [profile]. Drives the "Ajouter" pill into its "Envoyé" state;
  /// re-tapping then cancels the request via [onAdd].
  final bool pendingOutgoing;

  /// Fires with the photo URL currently shown + the tapped emoji — the
  /// reaction belongs to that specific photo.
  final void Function(String photo, String emoji)? onSendEmoji;

  /// Photo URL → emojis I've already sent on it. The rail renders a button
  /// filled only for the carousel photo currently in view.
  final Map<String, Set<String>> reactionsByPhoto;

  /// True when I've already sent [profile] a direct intro message — the
  /// in-card text field is replaced by a "message sent" state (one per peer).
  final bool alreadyMessaged;

  /// Send a one-off intro message to [profile] from the in-card text area.
  /// Null on non-interactive (background-deck) cards.
  final Future<void> Function(String)? onSendMessage;

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  // Which carousel photo is on screen — drives the reaction rail's target.
  int _photoIdx = 0;

  @override
  Widget build(BuildContext context) {
    // Alias widget fields to locals so the (long) build body below reads
    // unchanged.
    final profile = widget.profile;
    final photos = widget.photos;
    final onAdd = widget.onAdd;
    final pendingOutgoing = widget.pendingOutgoing;
    final alreadyMessaged = widget.alreadyMessaged;
    final onSendMessage = widget.onSendMessage;
    final idx = photos.isEmpty
        ? 0
        : _photoIdx.clamp(0, photos.length - 1);
    final currentPhoto = photos.isEmpty ? '' : photos[idx];
    final reactedEmojis =
        widget.reactionsByPhoto[currentPhoto] ?? const <String>{};
    final sendEmoji = widget.onSendEmoji;
    final onSendEmoji = sendEmoji == null
        ? null
        : (String emoji) => sendEmoji(currentPhoto, emoji);
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
          // Bright cyan halo hugging the card on every side — the "effet
          // lumineux" radiating out from behind it (no offset = even glow).
          BoxShadow(
            color: SC.accent.withValues(alpha: 0.55),
            blurRadius: 48,
            spreadRadius: 2,
          ),
          // Softer, wider cyan bloom dropping below for depth.
          BoxShadow(
            color: SC.meshCyan.withValues(alpha: 0.35),
            blurRadius: 90,
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
            if (photos.isNotEmpty)
              _CardPhotoCarousel(
                photos: photos,
                onIndexChanged: (i) => setState(() => _photoIdx = i),
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
                        // Friend request now lives in the rail (person-add
                        // button), so the old "Add" pill is gone — the card
                        // shows the direct message field here instead.
                        // Direct intro message — one per photo. Hidden on
                        // background-deck cards (onSendMessage null).
                        if (onSendMessage != null)
                          if (alreadyMessaged)
                            const _MessageSentPill()
                          else
                            _DirectMessageField(
                              onSend: onSendMessage,
                              peerName: profile.displayName,
                            ),
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
                      onAddFriend: onAdd,
                      pendingOutgoing: pendingOutgoing,
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

/// Horizontal photo carousel filling a Discover card. Swipe left/right to move
/// between this person's photos (the deck itself pages vertically, so the two
/// axes don't fight). Page dots sit at the TOP-CENTRE in a discreet greyed
/// white. Single-photo cards render just the image, no dots.
class _CardPhotoCarousel extends StatefulWidget {
  const _CardPhotoCarousel({required this.photos, this.onIndexChanged});

  final List<String> photos;

  /// Fires with the new photo index whenever the visible photo changes
  /// (swipe or tap). Lets the parent card target reactions at this photo.
  final ValueChanged<int>? onIndexChanged;

  @override
  State<_CardPhotoCarousel> createState() => _CardPhotoCarouselState();
}

class _CardPhotoCarouselState extends State<_CardPhotoCarousel> {
  int _index = 0;
  double _dragDx = 0;

  void _set(int i) {
    final n = widget.photos.length;
    if (n <= 1) return;
    final t = i.clamp(0, n - 1);
    if (t == _index) return;
    setState(() => _index = t);
    widget.onIndexChanged?.call(t);
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final i = photos.isEmpty ? 0 : _index.clamp(0, photos.length - 1);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Manual swipe + tap navigation — NO inner PageView, so there's no
        // gesture-arena fight with the vertical profile deck: a horizontal
        // drag is claimed here (the deck only wants vertical), a vertical
        // drag falls through to the deck, and a tap flips by which side was
        // touched. This is what actually makes browsing photos work on mobile.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: photos.length > 1 ? (_) => _dragDx = 0 : null,
          onHorizontalDragUpdate:
              photos.length > 1 ? (d) => _dragDx += d.delta.dx : null,
          onHorizontalDragEnd: photos.length > 1
              ? (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() > 100) {
                    _set(v < 0 ? _index + 1 : _index - 1); // fling
                  } else if (_dragDx.abs() > 40) {
                    _set(_dragDx < 0 ? _index + 1 : _index - 1); // drag
                  }
                }
              : null,
          onTapUp: photos.length > 1
              ? (d) {
                  final w = context.size?.width ?? 0;
                  if (w <= 0) return;
                  _set(d.localPosition.dx > w / 2 ? _index + 1 : _index - 1);
                }
              : null,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Image.network(
              photos.isEmpty ? '' : photos[i],
              key: ValueKey(i),
              fit: BoxFit.cover,
              // Centre crop — keeps the subject roughly in the middle of the
              // card whatever the source aspect ratio.
              alignment: Alignment.center,
              errorBuilder: (_, _, _) => const ColoredBox(color: SC.bubbleIn),
            ),
          ),
        ),
        if (photos.length > 1)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var j = 0; j < photos.length; j++) ...[
                    if (j > 0) const SizedBox(width: 6),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: j == i ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        // Discreet — greyed white, the active dot a touch
                        // brighter and wider.
                        color: j == i
                            ? Colors.white.withValues(alpha: 0.75)
                            : Colors.white.withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Vertical reaction rail rendered on the right side of a profile card —
/// ghosted "send-a-vibe" emojis, each dim by default and filled when tapped.
class _ReactionRail extends StatelessWidget {
  const _ReactionRail({
    this.onSendEmoji,
    this.reactedEmojis = const <String>{},
    this.onAddFriend,
    this.pendingOutgoing = false,
  });

  /// Fires with the tapped emoji string — handed to each
  /// [_ReactionEmojiButton]. Wired by the parent card to drop the emoji
  /// into the peer's DM thread, same behaviour as the legacy 👋 Coucou.
  final ValueChanged<String>? onSendEmoji;

  /// Emojis the local user has already sent to this peer — each
  /// matching button renders pre-filled so the rail survives refreshes.
  final Set<String> reactedEmojis;

  /// Send / cancel a friend request — wired to the person-add button at the
  /// bottom of the rail. Null on non-interactive cards.
  final VoidCallback? onAddFriend;

  /// True when a friend request to this peer is already pending — the
  /// person-add button shows its "sent" (accent) state.
  final bool pendingOutgoing;

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
        // Friend-request button at the bottom of the rail.
        if (onAddFriend != null) ...[
          const SizedBox(height: 10),
          _RailAddFriendButton(
            pending: pendingOutgoing,
            onTap: onAddFriend!,
          ),
        ],
      ],
    );
  }
}

/// Person-add button at the bottom of the reaction rail — sends a friend
/// request (or cancels a pending one). Matches the 48 px emoji buttons; turns
/// accent + check when a request is already pending.
class _RailAddFriendButton extends StatelessWidget {
  const _RailAddFriendButton({required this.pending, required this.onTap});
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: pending
              ? SC.accent.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: pending ? SC.accent : Colors.white.withValues(alpha: 0.20),
            width: pending ? 2 : 1,
          ),
        ),
        child: Icon(
          pending ? Icons.check_rounded : Icons.person_add_alt_1,
          size: pending ? 24 : 22,
          color: pending ? SC.accent : Colors.white,
        ),
      ),
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
  const _DirectMessageField({required this.onSend, this.peerName = ''});
  final Future<void> Function(String) onSend;

  /// The recipient's display name — its first word is woven into the hint
  /// ("Écris à Sarah…"). Falls back to the generic hint when empty.
  final String peerName;
  @override
  State<_DirectMessageField> createState() => _DirectMessageFieldState();
}

class _DirectMessageFieldState extends State<_DirectMessageField> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Rebuild on text changes AND on focus so the bar expands + reveals the
    // send arrow when tapped, and shrinks back when idle/empty.
    _ctrl.addListener(_onChanged);
    _focus.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _focus.removeListener(_onChanged);
    _focus.dispose();
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
    // Expanded once the field is tapped (focused) or has text: full width +
    // send arrow. Idle & empty: a slightly narrower compact pill, no arrow.
    final expanded = _focus.hasFocus || hasText;
    // First name only — weave it into the hint ("Écris à Sarah…"); fall back
    // to the generic hint when the peer has no name.
    final firstName = widget.peerName.trim().split(RegExp(r'\s+')).first;
    final hintText = firstName.isEmpty
        ? AppStrings.t('discover_message_hint')
        : AppStrings.t('discover_message_hint_name', args: {'name': firstName});
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      // Slightly narrower at rest; grows back to the full width on tap.
      width: expanded ? 270 : 232,
      decoration: BoxDecoration(
        // Neutral translucent dark over the photo.
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.30)),
      ),
      padding: EdgeInsets.fromLTRB(14, 3, expanded ? 5 : 16, 3),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              enabled: !_sending,
              minLines: 1,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              cursorColor: SC.accent,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                // The app theme fills inputs with navy (bubbleIn) — turn it
                // OFF here, that navy was the "fond bleu" behind the text.
                filled: false,
                hintText: hintText,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          // Send arrow (➤) inside the bar — appears once the field is tapped
          // or has text.
          if (expanded) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: (hasText && !_sending) ? _send : null,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: SC.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          ],
        ],
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
