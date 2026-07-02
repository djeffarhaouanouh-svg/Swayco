import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

import '../services/analytics.dart';
import '../services/platform_glass.dart';
import '../services/app_boot.dart';
import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/interests.dart';
import '../services/missions_service.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/profile_api.dart';
import '../services/remote_config.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/mesh_background.dart';
import '../widgets/emoji_burst.dart';
import '../widgets/missions_ring.dart';
import '../widgets/glass_panel.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<RemoteProfile> _profiles = const <RemoteProfile>[];
  bool _feedLoading = true;

  final List<({RemoteProfile profile, List<String> photos})> _cards = [];

  void _rebuildCards() {
    _cards.clear();
    for (final p in _profiles) {
      final photos = p.photos.where((u) => u.isNotEmpty).toList();
      final single = p.discoverPhotoUrl.isNotEmpty
          ? p.discoverPhotoUrl
          : (photos.isNotEmpty ? photos.first : p.avatarUrl);
      if (single.isNotEmpty) {
        _cards.add((profile: p, photos: <String>[single]));
      }
    }
  }

  Map<String, Set<String>> _myReactionsByPhoto = const {};
  Set<String> _directMessagedPeers = <String>{};

  // Tinder deck: current top-card index.
  int _currentIndex = 0;

  // Exposed so action buttons can trigger programmatic swipes.
  final _stackKey = GlobalKey<_TinderCardStackState>();

  // ── Search state ────────────────────────────────────────────────────────────
  bool _searchExpanded = false;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _searchDebounce;
  Timer? _pollTimer;
  String _myId = '';
  bool _searching = false;
  List<RemoteProfile> _searchResults = const [];
  List<Friendship> _myFriendships = const [];

  @override
  void initState() {
    super.initState();
    Analytics.track('screen_view', props: {'screen': 'discover'});
    _bootstrapSearch();
    _pollTimer = WebPoll.every(
      const Duration(seconds: 10),
      _refreshLiveSignals,
    );
  }

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
    } catch (_) {}
  }

  Future<void> _bootstrapSearch() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    MissionsService.instance.refresh(id);
    if (!isSupabaseReady || id.isEmpty) {
      setState(() => _feedLoading = false);
      AppBoot.markHomeReady();
      return;
    }
    try {
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _precacheAround(_currentIndex);
      });
    } catch (_) {
      if (mounted) setState(() => _feedLoading = false);
      AppBoot.markHomeReady();
    }
  }

  void _restoreCursor(String cursorId) {
    if (cursorId.isEmpty || _cards.isEmpty) return;
    final idx = _cards.indexWhere((c) => c.profile.id == cursorId);
    if (idx > 0) _currentIndex = idx;
  }

  void _persistCursor() {
    if (_cards.isEmpty) return;
    UserPrefs.saveDiscoverCursor(
      _cards[_currentIndex % _cards.length].profile.id,
    );
  }

  void _precacheAround(int index) {
    if (!mounted || _cards.isEmpty) return;
    final n = _cards.length;
    final seen = <String>{};
    for (var off = -1; off <= 5; off++) {
      final card = _cards[(index + off) % n];
      final url = card.photos.isNotEmpty ? card.photos.first : '';
      if (url.isNotEmpty && seen.add(url)) {
        precacheImage(NetworkImage(url), context).ignore();
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── Search ──────────────────────────────────────────────────────────────────

  void _expandSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
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
    if (mounted) _refreshLiveSignals();
  }

  // ── Friend request ──────────────────────────────────────────────────────────

  Future<void> _sendFriendRequest(RemoteProfile peer) async {
    final f = await FriendshipApi.sendRequest(meId: _myId, peerId: peer.id);
    Analytics.track(
      'friend_request_sent',
      props: {'source': 'discover', 'kind': 'request'},
    );
    if (!mounted) return;
    if (f != null) {
      setState(() => _myFriendships = [..._myFriendships, f]);
    }
  }

  FriendshipStatus _statusFor(RemoteProfile peer) {
    final (status, _) = FriendshipApi.statusWith(
      _myId,
      peer.id,
      _myFriendships,
    );
    return status;
  }

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
      _myFriendships =
          _myFriendships.where((f) => f.id != friendship.id).toList();
    });
    try {
      await FriendshipApi.remove(friendship.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _myFriendships = previous);
    }
  }

  Future<void> _toggleFriendRequest(RemoteProfile peer) async {
    if (_statusFor(peer) == FriendshipStatus.pendingOutgoing) {
      await _cancelFriendRequest(peer);
    } else {
      await _sendFriendRequest(peer);
    }
  }

  // ── Emoji reactions ─────────────────────────────────────────────────────────

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

  Future<void> _sendEmojiReaction(
    RemoteProfile peer,
    String photo,
    String emoji,
  ) async {
    final next = Map<String, Set<String>>.from(_myReactionsByPhoto);
    final current = Set<String>.from(next[photo] ?? const <String>{});
    current.add(emoji);
    next[photo] = current;
    setState(() => _myReactionsByPhoto = next);
    await _sendQuickMessage(
      peer,
      body: emoji,
      snack: '$emoji envoyé à ${peer.displayName}',
      discoverPhoto: photo,
      type: 'reaction',
    );
  }

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

  Future<void> _sendQuickMessage(
    RemoteProfile peer, {
    required String body,
    required String snack,
    String discoverPhoto = '',
    String type = 'text',
  }) async {
    if (_myId.isEmpty || peer.id.isEmpty) return;
    try {
      final local = await UserPrefs.loadProfile();
      final myProfile =
          isSupabaseReady ? await ProfileApi.fetchById(_myId) : null;
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
      Analytics.track('message_sent', props: {'source': 'discover', 'type': type});
      if (!mounted) return;
      _showAddedSnack(snack);
    } catch (e) {
      if (!mounted) return;
      _showAddedSnack('Envoi échoué : $e', isError: true);
    }
  }

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

  void _showAddedSnack(String text, {bool isError = false}) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final liftFromBottom =
        GlassNavBar.height + safeBottom + _kActionBarHeight + 16.0;
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
    if (_myId.isEmpty) return;
    setState(() {
      _feedLoading = true;
      _currentIndex = 0;
    });
    final feed = await ProfileApi.fetchDiscoverFeed(myId: _myId);
    if (!mounted) return;
    setState(() {
      _profiles = feed;
      _rebuildCards();
      _feedLoading = false;
    });
  }

  // ── Tinder swipe logic ──────────────────────────────────────────────────────

  void _onCardSwiped(bool isRight, RemoteProfile profile) {
    if (isRight) {
      HapticFeedback.lightImpact();
      _sendFriendRequest(profile);
    }
    setState(() {
      _currentIndex = (_currentIndex + 1) % _cards.length;
      _persistCursor();
      _precacheAround(_currentIndex);
    });
  }

  void _onActionSwipeLeft() => _stackKey.currentState?.triggerSwipe(false);
  void _onActionSwipeRight() => _stackKey.currentState?.triggerSwipe(true);

  // ── Build ───────────────────────────────────────────────────────────────────

  static const double _kActionBarHeight = 88.0;

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final deckTop = safeTop + _DiscoverHeader.height;
    final deckBottom = GlassNavBar.height + safeBottom + _kActionBarHeight;

    return Scaffold(
      backgroundColor: SC.bg,
      extendBody: true,
      body: MeshBackground(
        child: Stack(
          children: [
            // Cyan-blue ambient wash
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
            // Card deck
            Positioned(
              left: 0,
              right: 0,
              top: deckTop,
              bottom: deckBottom,
              child: _feedLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: SC.accent),
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => FocusScope.of(context).unfocus(),
                      child: _buildTinderStack(),
                    ),
            ),
            // Top bar
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
            // Online badge
            Positioned(
              top: deckTop + 10,
              left: 20,
              child: const _OnlineBadge(),
            ),
            // Tinder action buttons (X / ❤️)
            Positioned(
              left: 0,
              right: 0,
              bottom: GlassNavBar.height + safeBottom,
              height: _kActionBarHeight,
              child: _SwipeActionBar(
                onSwipeLeft: _onActionSwipeLeft,
                onSwipeRight: _onActionSwipeRight,
              ),
            ),
            // Search dismiss overlay
            if (_searchExpanded)
              Positioned.fill(
                top: safeTop + 64,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _collapseSearch,
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            // Search results dropdown
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

  Widget _buildTinderStack() {
    if (_cards.isEmpty) return _Empty(onReset: _reset);
    return _TinderCardStack(
      key: _stackKey,
      cards: _cards,
      currentIndex: _currentIndex,
      myReactionsByPhoto: _myReactionsByPhoto,
      directMessagedPeers: _directMessagedPeers,
      statusFor: _statusFor,
      onSwiped: _onCardSwiped,
      onSendEmoji: _toggleEmojiReaction,
      onSendMessage: _sendDirectMessage,
      onToggleFriend: _toggleFriendRequest,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Tinder card stack
// ══════════════════════════════════════════════════════════════════════════════

class _TinderCardStack extends StatefulWidget {
  const _TinderCardStack({
    super.key,
    required this.cards,
    required this.currentIndex,
    required this.myReactionsByPhoto,
    required this.directMessagedPeers,
    required this.statusFor,
    required this.onSwiped,
    required this.onSendEmoji,
    required this.onSendMessage,
    required this.onToggleFriend,
  });

  final List<({RemoteProfile profile, List<String> photos})> cards;
  final int currentIndex;
  final Map<String, Set<String>> myReactionsByPhoto;
  final Set<String> directMessagedPeers;
  final FriendshipStatus Function(RemoteProfile) statusFor;
  final void Function(bool isRight, RemoteProfile profile) onSwiped;
  final void Function(RemoteProfile, String photo, String emoji) onSendEmoji;
  final Future<void> Function(RemoteProfile, String photoUrl, String text) onSendMessage;
  final void Function(RemoteProfile) onToggleFriend;

  @override
  State<_TinderCardStack> createState() => _TinderCardStackState();
}

class _TinderCardStackState extends State<_TinderCardStack> {
  // Recreated on each index change so the GlobalKey cleanly binds to the
  // new top card state after the old one is disposed.
  GlobalKey<_DraggableCardState> _topCardKey = GlobalKey<_DraggableCardState>();

  // Progress [0, 1] broadcast to the second card for its scale animation.
  final _swipeProgress = ValueNotifier<double>(0.0);

  @override
  void didUpdateWidget(_TinderCardStack old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      _topCardKey = GlobalKey<_DraggableCardState>();
      _swipeProgress.value = 0.0;
    }
  }

  @override
  void dispose() {
    _swipeProgress.dispose();
    super.dispose();
  }

  void triggerSwipe(bool isRight) {
    _topCardKey.currentState?.programmaticSwipe(isRight);
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.cards;
    final n = cards.length;
    if (n == 0) return const SizedBox.shrink();
    final i = widget.currentIndex % n;

    return Stack(
      children: [
        // Third card (deepest, smallest)
        if (n >= 3)
          _StackCard(
            key: ValueKey('back_${(i + 2) % n}'),
            scale: 0.88,
            translateY: 22,
            child: _buildCardContent(cards[(i + 2) % n], interactive: false),
          ),
        // Second card — scales toward 1.0 as top card is dragged
        if (n >= 2)
          ValueListenableBuilder<double>(
            valueListenable: _swipeProgress,
            builder: (_, progress, child) {
              final t = progress.clamp(0.0, 1.0);
              return _StackCard(
                key: ValueKey('mid_${(i + 1) % n}'),
                scale: 0.94 + 0.06 * t,
                translateY: 12.0 - 12.0 * t,
                child: _buildCardContent(cards[(i + 1) % n], interactive: false),
              );
            },
          ),
        // Top card (draggable)
        KeyedSubtree(
          key: ValueKey('top_$i'),
          child: _DraggableCard(
            key: _topCardKey,
            onSwiped: (isRight) =>
                widget.onSwiped(isRight, cards[i].profile),
            onDragProgress: (p) => _swipeProgress.value = p,
            child: _buildCardContent(cards[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildCardContent(
    ({RemoteProfile profile, List<String> photos}) card, {
    bool interactive = true,
  }) {
    final profile = card.profile;
    final photos = card.photos;
    final firstPhoto = photos.isNotEmpty ? photos.first : '';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SizedBox.expand(
          child: _ProfileCard(
            key: ValueKey('card_${profile.id}_$interactive'),
            profile: profile,
            photos: photos,
            onAdd: () => widget.onToggleFriend(profile),
            pendingOutgoing:
                widget.statusFor(profile) == FriendshipStatus.pendingOutgoing,
            reactionsByPhoto: widget.myReactionsByPhoto,
            onSendEmoji: interactive
                ? (photo, emoji) => widget.onSendEmoji(profile, photo, emoji)
                : null,
            alreadyMessaged: widget.directMessagedPeers.contains(profile.id),
            onSendMessage: interactive
                ? (text) => widget.onSendMessage(profile, firstPhoto, text)
                : null,
          ),
        ),
      ),
    );
  }
}

// Simple non-interactive background card with transform.
class _StackCard extends StatelessWidget {
  const _StackCard({
    super.key,
    required this.child,
    required this.scale,
    required this.translateY,
  });

  final Widget child;
  final double scale;
  final double translateY;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: Transform.translate(
        offset: Offset(0, translateY),
        child: Transform.scale(scale: scale, child: child),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Draggable top card — handles swipe gesture + animations
// ══════════════════════════════════════════════════════════════════════════════

const double _kSwipeThreshold = 100.0;

class _DraggableCard extends StatefulWidget {
  const _DraggableCard({
    super.key,
    required this.child,
    required this.onSwiped,
    required this.onDragProgress,
  });

  final Widget child;
  final ValueChanged<bool> onSwiped;
  final ValueChanged<double> onDragProgress;

  @override
  State<_DraggableCard> createState() => _DraggableCardState();
}

class _DraggableCardState extends State<_DraggableCard>
    with SingleTickerProviderStateMixin {
  Offset _pos = Offset.zero;
  bool _isFlyingOff = false;

  late final AnimationController _ctrl = AnimationController(vsync: this);
  Animation<Offset>? _motion;
  int _animGeneration = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTick);
  }

  void _onTick() {
    final m = _motion;
    if (m == null) return;
    setState(() {
      _pos = m.value;
      widget.onDragProgress(
        (_pos.dx.abs() / _kSwipeThreshold).clamp(0.0, 1.0),
      );
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _animateTo(
    Offset target,
    Duration dur,
    Curve curve, {
    VoidCallback? onDone,
  }) {
    final gen = ++_animGeneration;
    _motion = Tween<Offset>(begin: _pos, end: target).animate(
      CurvedAnimation(parent: _ctrl, curve: curve),
    );
    _ctrl.duration = dur;
    _ctrl.value = 0;
    _ctrl.forward().then((_) {
      if (mounted &&
          _animGeneration == gen &&
          _ctrl.status == AnimationStatus.completed) {
        onDone?.call();
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_isFlyingOff) return;
    _ctrl.stop();
    _motion = null;
    setState(() {
      _pos += Offset(d.delta.dx, d.delta.dy * 0.35);
      widget.onDragProgress(
        (_pos.dx.abs() / _kSwipeThreshold).clamp(0.0, 1.0),
      );
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (_isFlyingOff) return;
    if (_pos.dx.abs() >= _kSwipeThreshold) {
      _flyOff(_pos.dx > 0);
    } else {
      _springBack();
    }
  }

  void _flyOff(bool right) {
    _isFlyingOff = true;
    final target = Offset(right ? 900.0 : -900.0, _pos.dy - 40);
    _animateTo(target, const Duration(milliseconds: 280), Curves.easeIn,
        onDone: () {
      if (mounted) widget.onSwiped(right);
    });
  }

  void _springBack() {
    _animateTo(Offset.zero, const Duration(milliseconds: 550), Curves.elasticOut,
        onDone: () {
      if (mounted) {
        setState(() => _pos = Offset.zero);
        widget.onDragProgress(0.0);
      }
    });
  }

  void programmaticSwipe(bool isRight) {
    if (_isFlyingOff) return;
    _flyOff(isRight);
  }

  double get _rotation => (_pos.dx / 280.0) * 0.22; // max ~12.5°

  @override
  Widget build(BuildContext context) {
    final likeOpacity = (_pos.dx / 70.0).clamp(0.0, 1.0);
    final nopeOpacity = (-_pos.dx / 70.0).clamp(0.0, 1.0);

    return GestureDetector(
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Transform.translate(
        offset: _pos,
        child: Transform.rotate(
          angle: _rotation,
          child: Stack(
            children: [
              widget.child,
              if (likeOpacity > 0.01)
                Positioned(
                  top: 36,
                  left: 24,
                  child: Opacity(
                    opacity: likeOpacity,
                    child: const _SwipeStamp(
                      text: 'LIKE',
                      color: Color(0xFF22C55E),
                    ),
                  ),
                ),
              if (nopeOpacity > 0.01)
                Positioned(
                  top: 36,
                  right: 24,
                  child: Opacity(
                    opacity: nopeOpacity,
                    child: const _SwipeStamp(
                      text: 'NOPE',
                      color: Color(0xFFFF3B5C),
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

// ══════════════════════════════════════════════════════════════════════════════
// LIKE / NOPE stamp overlay
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeStamp extends StatelessWidget {
  const _SwipeStamp({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Counter-rotate slightly so the stamp stays readable as the card tilts.
    final angle = text == 'LIKE' ? -0.3 : 0.3;
    return Transform.rotate(
      angle: angle,
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
            fontSize: 34,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
            shadows: [Shadow(color: color.withValues(alpha: 0.3), blurRadius: 8)],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Action buttons bar (X / ❤️)
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeActionBar extends StatelessWidget {
  const _SwipeActionBar({
    required this.onSwipeLeft,
    required this.onSwipeRight,
  });

  final VoidCallback onSwipeLeft;
  final VoidCallback onSwipeRight;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ActionButton(
          onTap: onSwipeLeft,
          size: 62,
          color: const Color(0xFFFF3B5C),
          icon: Icons.close_rounded,
          iconSize: 30,
        ),
        const SizedBox(width: 20),
        _ActionButton(
          onTap: onSwipeRight,
          size: 52,
          color: const Color(0xFF3B82F6),
          icon: Icons.star_rounded,
          iconSize: 26,
        ),
        const SizedBox(width: 20),
        _ActionButton(
          onTap: onSwipeRight,
          size: 62,
          color: const Color(0xFF22C55E),
          icon: Icons.favorite_rounded,
          iconSize: 30,
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.onTap,
    required this.size,
    required this.color,
    required this.icon,
    required this.iconSize,
  });

  final VoidCallback onTap;
  final double size;
  final Color color;
  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      bounce: true,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: SC.bubbleIn,
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: 0.35),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.22),
              blurRadius: 14,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Icon(icon, color: color, size: iconSize),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Online badge
// ══════════════════════════════════════════════════════════════════════════════

class _OnlineBadge extends StatefulWidget {
  const _OnlineBadge();

  @override
  State<_OnlineBadge> createState() => _OnlineBadgeState();
}

class _OnlineBadgeState extends State<_OnlineBadge> {
  final _rng = Random();
  int? _count;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _roll();
    RemoteConfig.version.addListener(_roll);
    _timer = Timer.periodic(const Duration(seconds: 18), (_) => _drift());
  }

  @override
  void dispose() {
    RemoteConfig.version.removeListener(_roll);
    _timer?.cancel();
    super.dispose();
  }

  int get _lo => RemoteConfig.integer('online_min', 40);
  int get _hi {
    final h = RemoteConfig.integer('online_max', 180);
    return h < _lo ? _lo : h;
  }

  void _roll() {
    if (!mounted) return;
    if (!RemoteConfig.flag('online_badge_enabled')) {
      setState(() => _count = null);
      return;
    }
    setState(() => _count = _lo + _rng.nextInt(_hi - _lo + 1));
  }

  void _drift() {
    if (!mounted || _count == null) return;
    setState(() => _count = (_count! + _rng.nextInt(7) - 3).clamp(_lo, _hi));
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    if (count == null || count <= 0) return const SizedBox.shrink();
    return GlassPanel(
      borderRadius: 999,
      color: const Color(0x4D000000),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF22C55E).withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            AppStrings.t('online_count', args: {'n': '$count'}),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Top header bar with search
// ══════════════════════════════════════════════════════════════════════════════

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

  static const double height = 72;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return ClipPath(
      clipper: const _BottomHugClipper(GlassNavBar.hugRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          color: Colors.white.withValues(alpha: 0.12),
          padding: EdgeInsets.only(
            top: topInset,
            bottom: GlassNavBar.hugRadius,
          ),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  if (!expanded)
                    _TypewriterTitle(
                      text: AppStrings.t('discover_title'),
                      style: SCText.h1,
                    ),
                  const Spacer(),
                  Transform.translate(
                    offset: const Offset(0, 2),
                    child: const MissionsScoreRing(),
                  ),
                  const SizedBox(width: 10),
                  Pressable(
                    behavior: HitTestBehavior.opaque,
                    bounce: true,
                    onTap: expanded ? null : onTapPill,
                    child: GlassPanel(
                      borderRadius: 999,
                      color: SC.glassStrong,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        width: expanded
                            ? (MediaQuery.sizeOf(context).width - 135).clamp(
                                180.0,
                                250.0,
                              )
                            : null,
                        padding: EdgeInsets.symmetric(
                          horizontal: expanded ? 16 : 10,
                          vertical: expanded ? 6 : 10,
                        ),
                        child: Row(
                          mainAxisSize: expanded
                              ? MainAxisSize.max
                              : MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.search,
                              size: 22,
                              color: SC.textMuted,
                            ),
                            if (expanded) const SizedBox(width: 6),
                            if (expanded)
                              Expanded(
                                child: TextSelectionTheme(
                                  data: TextSelectionThemeData(
                                    cursorColor: SC.accent,
                                    selectionColor:
                                        SC.accent.withValues(alpha: 0.35),
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
                                      fontSize: 15,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: AppStrings.t(
                                        'search_friend_hint',
                                      ),
                                      hintStyle: const TextStyle(
                                        color: SC.textMuted,
                                        fontSize: 15,
                                      ),
                                      border: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                    ),
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
                                    size: 18,
                                    color: SC.textMuted,
                                  ),
                                ),
                              ),
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
      ),
    );
  }
}

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

class _TypewriterTitle extends StatefulWidget {
  const _TypewriterTitle({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_TypewriterTitle> createState() => _TypewriterTitleState();
}

class _TypewriterTitleState extends State<_TypewriterTitle> {
  String _shown = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _animate();
  }

  void _animate() {
    _timer?.cancel();
    final full = widget.text;
    _shown = '';
    var shown = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 75), (t) {
      if (!mounted || shown >= full.length) {
        t.cancel();
        return;
      }
      shown++;
      setState(() => _shown = full.substring(0, shown));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(_shown, style: widget.style, maxLines: 1);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Search results panel
// ══════════════════════════════════════════════════════════════════════════════

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
    if (query.isEmpty) return const SizedBox.shrink();
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
                      style: const TextStyle(
                        color: SC.textMuted,
                        fontSize: 12,
                      ),
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

// ══════════════════════════════════════════════════════════════════════════════
// Profile card
// ══════════════════════════════════════════════════════════════════════════════

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
  final List<String> photos;
  final VoidCallback onAdd;
  final bool pendingOutgoing;
  final void Function(String photo, String emoji)? onSendEmoji;
  final Map<String, Set<String>> reactionsByPhoto;
  final bool alreadyMessaged;
  final Future<void> Function(String)? onSendMessage;

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final photos = widget.photos;
    final onAdd = widget.onAdd;
    final pendingOutgoing = widget.pendingOutgoing;
    final alreadyMessaged = widget.alreadyMessaged;
    final onSendMessage = widget.onSendMessage;
    final currentPhoto = photos.isEmpty ? '' : photos.first;
    final reactedEmojis =
        widget.reactionsByPhoto[currentPhoto] ?? const <String>{};
    final sendEmoji = widget.onSendEmoji;
    final onSendEmoji = sendEmoji == null
        ? null
        : (String emoji) => sendEmoji(currentPhoto, emoji);

    final flag =
        (profile.city.trim().isNotEmpty
            ? countryFlagFor(profile.country)
            : null) ??
        findLanguageByCode(profile.language)?.flag ??
        '';
    final locationLabel = [
      profile.city.trim(),
      profile.country.trim(),
    ].where((s) => s.isNotEmpty).join(', ');
    final online = !profile.hideOnlineStatus &&
        profile.lastSeen != null &&
        DateTime.now().difference(profile.lastSeen!) <
            const Duration(minutes: 2);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassNavBar.hugRadius),
        boxShadow: [
          BoxShadow(
            color: SC.accent.withValues(alpha: 0.55),
            blurRadius: 48,
            spreadRadius: 2,
          ),
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
            if (currentPhoto.isNotEmpty) _CardPhoto(photoUrl: currentPhoto),
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                        if (online) ...[
                          const SizedBox(height: 5),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: SC.online,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                AppStrings.t('online_now'),
                                style: const TextStyle(
                                  color: SC.online,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (profile.interests.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final tag in profile.interests.take(3))
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.20),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.35,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    interestLabel(tag),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 14),
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

class _CardPhoto extends StatelessWidget {
  const _CardPhoto({required this.photoUrl});

  final String photoUrl;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      photoUrl,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const ColoredBox(color: SC.bubbleIn),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Reaction rail
// ══════════════════════════════════════════════════════════════════════════════

class _ReactionRail extends StatelessWidget {
  const _ReactionRail({
    this.onSendEmoji,
    this.reactedEmojis = const <String>{},
    this.onAddFriend,
    this.pendingOutgoing = false,
  });

  final ValueChanged<String>? onSendEmoji;
  final Set<String> reactedEmojis;
  final VoidCallback? onAddFriend;
  final bool pendingOutgoing;

  static const _emojis = <String>['🔥', '😍', '❤️'];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _emojis.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _ReactionEmojiButton(
            emoji: _emojis[i],
            index: i,
            reacted: reactedEmojis.contains(_emojis[i]),
            onSend: onSendEmoji == null
                ? null
                : () => onSendEmoji!(_emojis[i]),
          ),
        ],
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

class _ReactionEmojiButton extends StatefulWidget {
  const _ReactionEmojiButton({
    required this.emoji,
    required this.reacted,
    this.onSend,
    this.index = 0,
  });

  final String emoji;
  final int index;
  final bool reacted;
  final VoidCallback? onSend;

  @override
  State<_ReactionEmojiButton> createState() => _ReactionEmojiButtonState();
}

class _ReactionEmojiButtonState extends State<_ReactionEmojiButton>
    with TickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.0,
        end: 1.35,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.35,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 65,
    ),
  ]).animate(_pop);

  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breathe.dispose();
    _pop.dispose();
    super.dispose();
  }

  void _handleTap(BuildContext ctx) {
    HapticFeedback.lightImpact();
    _pop.forward(from: 0);
    if (!widget.reacted) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final pos = box.localToGlobal(box.size.center(Offset.zero));
        EmojiBurst.show(ctx, position: pos, emoji: widget.emoji);
      }
    }
    widget.onSend!();
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (ctx) {
        final glyph = Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 160),
            style: TextStyle(
              fontSize: widget.reacted ? 24 : 22,
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
            child: AnimatedBuilder(
              animation: Listenable.merge([_breathe, _pop]),
              builder: (context, child) => Transform.scale(
                scale: (1.0 + 0.20 * _breathe.value) * _popScale.value,
                child: child,
              ),
              child: widget.emoji == '❤️'
                  ? Icon(
                      widget.reacted
                          ? Icons.favorite
                          : Icons.favorite_border,
                      size: widget.reacted ? 26 : 24,
                      color: widget.reacted
                          ? const Color(0xFFFF3B5C)
                          : Colors.white,
                    )
                  : Text(widget.emoji),
            ),
          ),
        );

        final Widget surface = useShaderGlass
            ? lg.GlassContainer(
                useOwnLayer: true,
                clipBehavior: Clip.antiAlias,
                width: 48,
                height: 48,
                shape: const lg.LiquidOval(),
                settings: lg.LiquidGlassSettings(
                  blur: 6,
                  thickness: 12,
                  glassColor: widget.reacted
                      ? const Color(0x3322D3EE)
                      : const Color(0x14FFFFFF),
                  refractiveIndex: 1.3,
                  glowIntensity: widget.reacted ? 1.0 : 0.5,
                ),
                child: glyph,
              )
            : AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: widget.reacted
                      ? Colors.white.withValues(alpha: 0.18)
                      : Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: widget.reacted ? 0.85 : 0.20,
                    ),
                    width: widget.reacted ? 2 : 1,
                  ),
                ),
                child: glyph,
              );

        return Pressable(
          behavior: HitTestBehavior.opaque,
          bounce: true,
          onTap: widget.onSend == null ? null : () => _handleTap(ctx),
          child: surface,
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Direct message field
// ══════════════════════════════════════════════════════════════════════════════

class _DirectMessageField extends StatefulWidget {
  const _DirectMessageField({required this.onSend, this.peerName = ''});
  final Future<void> Function(String) onSend;
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
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _ctrl.text.trim().isNotEmpty;
    final expanded = _focus.hasFocus || hasText;
    final firstName = widget.peerName.trim().split(RegExp(r'\s+')).first;
    final hintText = firstName.isEmpty
        ? AppStrings.t('discover_message_hint')
        : AppStrings.t(
            'discover_message_hint_name',
            args: {'name': firstName},
          );
    return GlassPanel(
      borderRadius: 24,
      color: const Color(0x80000000),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: expanded ? 270 : 232,
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
      ),
    );
  }
}

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

// ══════════════════════════════════════════════════════════════════════════════
// Empty state
// ══════════════════════════════════════════════════════════════════════════════

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
