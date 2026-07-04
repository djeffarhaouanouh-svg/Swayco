import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics.dart';
import '../services/app_boot.dart';
import '../services/app_strings.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/interests.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/missions_service.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

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

  Future<void> _sendFriendRequest(RemoteProfile peer) async {
    final f = await FriendshipApi.sendRequest(meId: _myId, peerId: peer.id);
    Analytics.track('friend_request_sent', props: {'source': 'discover'});
    if (!mounted || f == null) return;
    setState(() => _myFriendships = [..._myFriendships, f]);
  }

  FriendshipStatus _statusFor(RemoteProfile peer) =>
      FriendshipApi.statusWith(_myId, peer.id, _myFriendships).$1;

  void _onCardSwiped(bool isRight, RemoteProfile profile) {
    if (isRight) {
      HapticFeedback.lightImpact();
      _sendFriendRequest(profile);
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
    final navBottom = GlassNavBar.totalReservedHeight + safeBottom;
    // Buttons sit just above the nav bar
    final btnBottom = navBottom + 8;
    // Card stops above the action buttons (8px breathing room)
    final cardBottom = btnBottom + actionH + 8;
    final tabBarH = safeTop + _TopTabBar.height;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBody: true,
      body: Stack(
        children: [
          // ── Card — de top:0 jusqu'au-dessus des boutons action ──────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: cardBottom,
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
                      ),
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
            ),
          ),

          // ── Boutons action — sur le gradient sombre de la card ────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: btnBottom,
            height: actionH,
            child: _SwipeActionBar(
              height: actionH,
              onUndo: _onActionUndo,
              onNope: _onSwipeLeft,
              onSuperLike: _onSwipeRight,
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
            Positioned(
              left: 12,
              right: 12,
              top: tabBarH + 8,
              child: _SearchOverlay(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                loading: _searching,
                results: _searchResults,
                query: _searchCtrl.text.trim(),
                statusFor: _statusFor,
                onChanged: _onSearchChanged,
                onClose: _closeSearch,
                onAdd: _sendFriendRequest,
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
// Top Tinder-style tab bar (frosted glass dark)
// ══════════════════════════════════════════════════════════════════════════════

class _TopTabBar extends StatelessWidget {
  const _TopTabBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTabSelected,
    required this.onSearch,
    required this.onSettings,
    this.topInset = 0,
  });

  final List<String> tabs;
  final int activeIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final double topInset;

  // Content height (excluding safe-area top inset)
  static const double height = 52.0;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          height: height + topInset,
          color: Colors.transparent,
          padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
          child: Row(
            children: [
              // Settings / filter icon
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSettings,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.tune_rounded, color: Colors.white, size: 24),
                ),
              ),
              // Tab pills (scrollable in case overflow)
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < tabs.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          _TabPill(
                            label: tabs[i],
                            active: i == activeIndex,
                            onTap: () => onTabSelected(i),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // Search icon
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSearch,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.search_rounded, color: Colors.white, size: 24),
                ),
              ),
              const SizedBox(width: 4),
              // Boost / lightning icon
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.bolt_rounded, color: Color(0xFFC77DFF), size: 26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
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
  });

  final List<({RemoteProfile profile, List<String> photos})> cards;
  final int currentIndex;
  final void Function(bool isRight, RemoteProfile profile) onSwiped;

  @override
  State<_TinderCardStack> createState() => _TinderCardStackState();
}

class _TinderCardStackState extends State<_TinderCardStack> {
  GlobalKey<_DraggableCardState> _topKey = GlobalKey<_DraggableCardState>();
  final _progress = ValueNotifier<double>(0.0);

  @override
  void didUpdateWidget(_TinderCardStack old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      _topKey = GlobalKey<_DraggableCardState>();
      _progress.value = 0.0;
    }
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
              child: _buildCard(widget.cards[i]),
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
        photos: card.photos,
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
  });
  final Widget child;
  final ValueChanged<bool> onSwiped;
  final ValueChanged<double> onProgress;

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

  @override
  Widget build(BuildContext context) {
    final angle = (_pos.dx / 320.0) * 0.20;
    final likeOpacity = (_pos.dx / 65.0).clamp(0.0, 1.0);
    final nopeOpacity = (-_pos.dx / 65.0).clamp(0.0, 1.0);

    return GestureDetector(
      onPanUpdate: (d) {
        if (_flying) return;
        _ctrl.stop();
        _anim = null;
        setState(() {
          _pos += Offset(d.delta.dx, d.delta.dy * 0.3);
          widget.onProgress((_pos.dx.abs() / _kThreshold).clamp(0.0, 1.0));
        });
      },
      onPanEnd: (_) {
        if (_flying) return;
        if (_pos.dx.abs() >= _kThreshold) {
          _flyOff(_pos.dx > 0);
        } else {
          _springBack();
        }
      },
      child: Transform.translate(
        offset: _pos,
        child: Transform.rotate(
          angle: angle,
          child: Stack(
            children: [
              widget.child,
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
              alignment: Alignment.topCenter,
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

          // ── Photo dots ─────────────────────────────────────────────────
          if (photos.length > 1)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: _PhotoDots(count: photos.length, active: _photoIndex),
            ),

          // ── Gradients haut + bas ────────────────────────────────────────
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    // haut : fondu dark → transparent (symétrique du bas)
                    Colors.black.withValues(alpha: 0.62),
                    Colors.black.withValues(alpha: 0.20),
                    Colors.transparent,
                    // bas : fondu transparent → noir opaque (même logique que haut)
                    Colors.black.withValues(alpha: 0.50),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.12, 0.40, 0.68, 1.0],
                ),
              ),
            ),
          ),

          // ── Bottom info ─────────────────────────────────────────────────
          Positioned(
            left: 16,
            right: 56,
            bottom: 18,
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
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          shadows: [Shadow(color: Color(0x55000000), blurRadius: 8)],
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
                // Interests — real data from profile.interests (Supabase)
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
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final tag in p.interests.take(6))
                        _InterestChip(label: interestLabel(tag)),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // ── Info button ─────────────────────────────────────────────────
          Positioned(
            right: 14,
            bottom: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ProfileScreen(userId: p.id),
                ),
              ),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.45),
                        width: 1.2,
                      ),
                    ),
                    child: const Icon(Icons.keyboard_arrow_up_rounded,
                        color: Colors.white, size: 22),
                  ),
                ),
              ),
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
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 3,
              decoration: BoxDecoration(
                color: i == active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(2),
              ),
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
    return ClipRRect(
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
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Action bar — 5 glass circle buttons (Tinder style)
// ══════════════════════════════════════════════════════════════════════════════

class _SwipeActionBar extends StatelessWidget {
  const _SwipeActionBar({
    required this.height,
    required this.onUndo,
    required this.onNope,
    required this.onSuperLike,
    required this.onLike,
    required this.onMessage,
  });

  final double height;
  final VoidCallback onUndo;
  final VoidCallback onNope;
  final VoidCallback onSuperLike;
  final VoidCallback onLike;
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
            size: 50,
            iconSize: 22,
            icon: Icons.replay_rounded,
            color: const Color(0xFFFBBF24),
            onTap: onUndo,
          ),
          const SizedBox(width: 14),
          _GlassButton(
            size: 64,
            iconSize: 30,
            icon: Icons.close_rounded,
            color: const Color(0xFFFF4458),
            onTap: onNope,
          ),
          const SizedBox(width: 14),
          _GlassButton(
            size: 52,
            iconSize: 24,
            icon: Icons.star_rounded,
            color: const Color(0xFF38BDF8),
            onTap: onSuperLike,
          ),
          const SizedBox(width: 14),
          _GlassButton(
            size: 64,
            iconSize: 30,
            icon: Icons.favorite_rounded,
            color: const Color(0xFF3DCA72),
            onTap: onLike,
          ),
          const SizedBox(width: 14),
          _GlassButton(
            size: 50,
            iconSize: 22,
            icon: Icons.send_rounded,
            color: const Color(0xFF22D3EE),
            onTap: onMessage,
          ),
        ],
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Pressable(
      bounce: true,
      onTap: onTap,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.10),
              border: Border.all(
                color: color.withValues(alpha: 0.60),
                width: 1.8,
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
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Search overlay
// ══════════════════════════════════════════════════════════════════════════════

class _SearchOverlay extends StatelessWidget {
  const _SearchOverlay({
    required this.controller,
    required this.focusNode,
    required this.loading,
    required this.results,
    required this.query,
    required this.statusFor,
    required this.onChanged,
    required this.onClose,
    required this.onAdd,
    required this.onOpen,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool loading;
  final List<RemoteProfile> results;
  final String query;
  final FriendshipStatus Function(RemoteProfile) statusFor;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;
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
            children: [
              // Search field
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded, color: Colors.white70, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: onChanged,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                        cursorColor: Colors.white,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'Rechercher un profil…',
                          hintStyle: TextStyle(color: Colors.white54, fontSize: 15),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: onClose,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                      ),
                    ),
                  ],
                ),
              ),
              if (query.isNotEmpty) ...[
                Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
                _buildResults(),
              ],
            ],
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
