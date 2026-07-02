import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics.dart';
import '../services/app_boot.dart';
import '../services/app_strings.dart';
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

  int _currentIndex = 0;
  final _stackKey = GlobalKey<_TinderCardStackState>();

  // ── Search ──────────────────────────────────────────────────────────────────
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
      if (!mounted) return;
      setState(() => _myFriendships = mine);
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
        ProfileApi.fetchDiscoverFeed(myId: id),
        UserPrefs.loadDiscoverCursor(),
      ]).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _myFriendships = results[0] as List<Friendship>;
        _profiles = results[1] as List<RemoteProfile>;
        _rebuildCards();
        _restoreCursor(results[2] as String);
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

  // ── Swipe logic ─────────────────────────────────────────────────────────────

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

  void _onActionUndo() {
    if (_cards.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex - 1 + _cards.length) % _cards.length;
    });
  }

  void _onActionSwipeLeft() => _stackKey.currentState?.triggerSwipe(false);
  void _onActionSwipeRight() => _stackKey.currentState?.triggerSwipe(true);

  // ── Build ───────────────────────────────────────────────────────────────────

  static const double _kActionBarHeight = 100.0;

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
            // Ambient gradient
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.2,
                    colors: [
                      SC.meshCyan.withValues(alpha: 0.40),
                      SC.meshBlue.withValues(alpha: 0.25),
                      SC.meshNavy.withValues(alpha: 0.18),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
            // Card deck
            Positioned(
              left: 12,
              right: 12,
              top: deckTop,
              bottom: deckBottom,
              child: _feedLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: SC.accent),
                    )
                  : _buildTinderStack(),
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
              top: deckTop + 14,
              left: 28,
              child: const _OnlineBadge(),
            ),
            // Tinder action buttons
            Positioned(
              left: 0,
              right: 0,
              bottom: GlassNavBar.height + safeBottom,
              height: _kActionBarHeight,
              child: _SwipeActionBar(
                onUndo: _onActionUndo,
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
      onSwiped: _onCardSwiped,
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
}

// ══════════════════════════════════════════════════════════════════════════════
// Tinder card stack
// ══════════════════════════════════════════════════════════════════════════════

class _TinderCardStack extends StatefulWidget {
  const _TinderCardStack({
    super.key,
    required this.cards,
    required this.currentIndex,
    required this.onSwiped,
  });

  final List<({RemoteProfile profile, List<String> photos})> cards;
  final int currentIndex;
  final void Function(bool isRight, RemoteProfile profile) onSwiped;

  @override
  State<_TinderCardStack> createState() => _TinderCardStackState();
}

class _TinderCardStackState extends State<_TinderCardStack> {
  GlobalKey<_DraggableCardState> _topCardKey = GlobalKey<_DraggableCardState>();
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
        // Third card — deepest, smallest
        if (n >= 3)
          _StackCard(
            key: ValueKey('back_${(i + 2) % n}'),
            scale: 0.88,
            translateY: 20,
            child: _buildCard(cards[(i + 2) % n]),
          ),
        // Second card — scales toward 1.0 as top card moves
        if (n >= 2)
          ValueListenableBuilder<double>(
            valueListenable: _swipeProgress,
            builder: (_, progress, child) {
              final t = progress.clamp(0.0, 1.0);
              return _StackCard(
                key: ValueKey('mid_${(i + 1) % n}'),
                scale: 0.94 + 0.06 * t,
                translateY: 10.0 - 10.0 * t,
                child: _buildCard(cards[(i + 1) % n]),
              );
            },
          ),
        // Top card — interactive
        KeyedSubtree(
          key: ValueKey('top_$i'),
          child: _DraggableCard(
            key: _topCardKey,
            onSwiped: (isRight) => widget.onSwiped(isRight, cards[i].profile),
            onDragProgress: (p) => _swipeProgress.value = p,
            child: _buildCard(cards[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(({RemoteProfile profile, List<String> photos}) card) {
    return SizedBox.expand(
      child: _TinderCard(
        key: ValueKey(card.profile.id),
        profile: card.profile,
        photoUrl: card.photos.isNotEmpty ? card.photos.first : '',
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Background stack card helper
// ══════════════════════════════════════════════════════════════════════════════

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
// Draggable top card — gesture + animations
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
    _animateTo(target, const Duration(milliseconds: 300), Curves.easeIn,
        onDone: () {
      if (mounted) widget.onSwiped(right);
    });
  }

  void _springBack() {
    _animateTo(
      Offset.zero,
      const Duration(milliseconds: 550),
      Curves.elasticOut,
      onDone: () {
        if (mounted) {
          setState(() => _pos = Offset.zero);
          widget.onDragProgress(0.0);
        }
      },
    );
  }

  void programmaticSwipe(bool isRight) {
    if (_isFlyingOff) return;
    _flyOff(isRight);
  }

  double get _rotation => (_pos.dx / 300.0) * 0.22;

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
                  top: 48,
                  left: 28,
                  child: Opacity(
                    opacity: likeOpacity,
                    child: const _SwipeStamp(
                      text: 'LIKE',
                      color: Color(0xFF3DCA72),
                    ),
                  ),
                ),
              if (nopeOpacity > 0.01)
                Positioned(
                  top: 48,
                  right: 28,
                  child: Opacity(
                    opacity: nopeOpacity,
                    child: const _SwipeStamp(
                      text: 'NOPE',
                      color: Color(0xFFFF4458),
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
// LIKE / NOPE stamp (Tinder style)
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeStamp extends StatelessWidget {
  const _SwipeStamp({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final angle = text == 'LIKE' ? -0.28 : 0.28;
    return Transform.rotate(
      angle: angle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color, width: 4),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 36,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Tinder-style 5-button action bar
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeActionBar extends StatelessWidget {
  const _SwipeActionBar({
    required this.onUndo,
    required this.onSwipeLeft,
    required this.onSwipeRight,
  });

  final VoidCallback onUndo;
  final VoidCallback onSwipeLeft;
  final VoidCallback onSwipeRight;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ActionButton(
          onTap: onUndo,
          size: 52,
          color: const Color(0xFFF5A623),
          icon: Icons.replay_rounded,
          iconSize: 24,
        ),
        const SizedBox(width: 18),
        _ActionButton(
          onTap: onSwipeLeft,
          size: 68,
          color: const Color(0xFFFF4458),
          icon: Icons.close_rounded,
          iconSize: 34,
        ),
        const SizedBox(width: 18),
        _ActionButton(
          onTap: onSwipeRight,
          size: 54,
          color: const Color(0xFF22D3EE),
          icon: Icons.star_rounded,
          iconSize: 28,
        ),
        const SizedBox(width: 18),
        _ActionButton(
          onTap: onSwipeRight,
          size: 68,
          color: const Color(0xFF3DCA72),
          icon: Icons.favorite_rounded,
          iconSize: 34,
        ),
        const SizedBox(width: 18),
        _ActionButton(
          onTap: onSwipeRight,
          size: 52,
          color: const Color(0xFFA855F7),
          icon: Icons.bolt_rounded,
          iconSize: 26,
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
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon, color: color, size: iconSize),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Tinder-style card — full-bleed photo, gradient, name + interests
// ══════════════════════════════════════════════════════════════════════════════

class _TinderCard extends StatelessWidget {
  const _TinderCard({
    super.key,
    required this.profile,
    required this.photoUrl,
  });

  final RemoteProfile profile;
  final String photoUrl;

  @override
  Widget build(BuildContext context) {
    final flag = (profile.city.trim().isNotEmpty
            ? countryFlagFor(profile.country)
            : null) ??
        findLanguageByCode(profile.language)?.flag ??
        '';
    final online = !profile.hideOnlineStatus &&
        profile.lastSeen != null &&
        DateTime.now().difference(profile.lastSeen!) <
            const Duration(minutes: 2);
    final locationLabel = [profile.city.trim(), profile.country.trim()]
        .where((s) => s.isNotEmpty)
        .join(', ');

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Photo (or dark fallback)
          const ColoredBox(color: Color(0xFF1A1A2E)),
          if (photoUrl.isNotEmpty)
            Image.network(
              photoUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          // Bottom gradient — starts mid-card, full black at bottom
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.90),
                  ],
                  stops: const [0.0, 0.45, 0.72, 1.0],
                ),
              ),
            ),
          ),
          // Info at bottom-left
          Positioned(
            left: 20,
            right: 20,
            bottom: 22,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name + flag + online dot
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                ProfileScreen(userId: profile.id),
                          ),
                        ),
                        child: Text(
                          profile.displayName.isEmpty
                              ? '—'
                              : profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            shadows: [
                              Shadow(
                                color: Color(0x66000000),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (flag.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Text(flag, style: const TextStyle(fontSize: 26)),
                    ],
                    if (online) ...[
                      const SizedBox(width: 10),
                      Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: const Color(0xFF22C55E),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF22C55E)
                                  .withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                // Location
                if (locationLabel.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          locationLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.80),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // Interests section
                if (profile.interests.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  // "Interests" header
                  Row(
                    children: [
                      Icon(
                        Icons.apps_rounded,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.70),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        AppStrings.t('interests_label'),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in profile.interests.take(4))
                        _InterestChip(label: interestLabel(tag)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // ℹ button — opens full profile page
          Positioned(
            bottom: 22,
            right: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ProfileScreen(userId: profile.id),
                ),
              ),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.50),
                    width: 1.5,
                  ),
                ),
                child: const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InterestChip extends StatelessWidget {
  const _InterestChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.17),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.40),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
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
                            ? (MediaQuery.sizeOf(context).width - 135)
                                .clamp(180.0, 250.0)
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
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 7,
              ),
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
