import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/greetings.dart';
import '../services/languages.dart';
import '../services/like_api.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/whatsapp_call_theme.dart';
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
  // bootstrap. Excludes me, anyone I've blocked / who's blocked me, and
  // accepted friends.
  List<RemoteProfile> _profiles = const <RemoteProfile>[];
  bool _feedLoading = true;

  int _topIndex = 0;
  // Profile ids I've already liked — heart renders filled for these.
  // Hydrated from Supabase on bootstrap so the state survives restarts /
  // multi-device; mutated optimistically on every tap, written through
  // LikeApi.like / LikeApi.unlike.
  Set<String> _likedIds = <String>{};

  // Drag state for the top card.
  Offset _drag = Offset.zero;
  Size _cardSize = Size.zero;
  late final AnimationController _ctrl;
  Offset _animFrom = Offset.zero;
  Offset _animTo = Offset.zero;
  bool _isFlying = false; // true => on completion, advance the index

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

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )
      ..addListener(() {
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        setState(() => _drag = Offset.lerp(_animFrom, _animTo, t)!);
      })
      ..addStatusListener((s) {
        if (s != AnimationStatus.completed) return;
        if (_isFlying) {
          setState(() {
            _topIndex += 1;
            _drag = Offset.zero;
            _isFlying = false;
          });
        }
      });
    _bootstrapSearch();
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
      if (!mounted) return;
      setState(() {
        _myFriendships = mine;
        _likedIds = liked;
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
      final feed = await ProfileApi.fetchDiscoverFeed(myId: id);
      if (!mounted) return;
      setState(() {
        _myFriendships = mine;
        _likedIds = liked;
        _profiles = feed;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('like_save_failed'))),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _searchDebounce?.cancel();
    _pollTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

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
    _searchDebounce =
        Timer(const Duration(milliseconds: 250), () => _runSearch(value));
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
      final results = await ProfileApi.searchByFirstName(
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
      // Seed a 👋 so the conversation appears on both sides immediately
      // — best-effort, ignored on failure.
      unawaited(Greetings.sendIntroMessage(myId: _myId, peerId: peer.id));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(f == null
            ? 'Erreur — Supabase non configuré'
            : 'Demande envoyée à ${peer.displayName}'),
        duration: const Duration(seconds: 2),
        backgroundColor: WhatsAppCallTheme.bar,
      ),
    );
  }

  FriendshipStatus _statusFor(RemoteProfile peer) {
    final (status, _) =
        FriendshipApi.statusWith(_myId, peer.id, _myFriendships);
    return status;
  }

  void _onPanStart(DragStartDetails _) {
    if (_ctrl.isAnimating) {
      _ctrl.stop();
      if (_isFlying) {
        _topIndex += 1;
        _isFlying = false;
        _drag = Offset.zero;
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() => _drag += d.delta);
  }

  void _onPanEnd(DragEndDetails d) {
    final w = _cardSize.width;
    final vx = d.velocity.pixelsPerSecond.dx;
    // Trigger if dragged ~25% of the card OR flicked fast enough.
    final triggered = (w > 0 && _drag.dx.abs() > w * 0.25) || vx.abs() > 500;
    if (triggered) {
      _flyOff(vx.abs() > 500 ? (vx >= 0 ? 1 : -1) : (_drag.dx >= 0 ? 1 : -1));
    } else {
      _springBack();
    }
  }

  /// Animate the top card off-screen. [direction] is -1 for a swipe to the
  /// LEFT and +1 for a swipe to the RIGHT.
  ///
  /// - Swipe left  → send a friend request to the current profile so the
  ///   conversation shows up in the Messages page, then advance.
  /// - Swipe right → just advance to the next profile.
  void _flyOff(int direction) {
    if (direction < 0 && _topIndex < _profiles.length) {
      _sendFriendRequest(_profiles[_topIndex]);
    }
    _animFrom = _drag;
    _animTo = Offset(direction * (_cardSize.width + 200), _drag.dy + 80);
    _isFlying = true;
    _ctrl
      ..duration = const Duration(milliseconds: 240)
      ..forward(from: 0);
  }

  void _springBack() {
    _animFrom = _drag;
    _animTo = Offset.zero;
    _isFlying = false;
    _ctrl
      ..duration = const Duration(milliseconds: 220)
      ..forward(from: 0);
  }

  void _advance() {
    if (_topIndex >= _profiles.length) return;
    setState(() => _topIndex += 1);
  }

  void _back() {
    if (_topIndex <= 0 || _ctrl.isAnimating) return;
    final w = _cardSize.width == 0
        ? MediaQuery.of(context).size.width
        : _cardSize.width;
    // Place the previous card off-screen on the left, then animate it back
    // to centre. Slightly slower than the fly-off because users notice the
    // returning motion more than the leaving one.
    setState(() {
      _topIndex -= 1;
      _drag = Offset(-(w + 200), 60);
    });
    _animFrom = _drag;
    _animTo = Offset.zero;
    _isFlying = false;
    _ctrl
      ..duration = const Duration(milliseconds: 320)
      ..forward(from: 0);
  }

  /// Sends a "👋 Coucou !" message to the visible profile via ChatApi.
  /// The conversation id is the same deterministic dm-{a}-{b} key the
  /// chat list uses, so the message lands directly in their thread.
  Future<void> _sendHello(RemoteProfile peer) async {
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
        body: '👋 Coucou !',
        language: myLang,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('👋 envoyé à ${peer.displayName}'),
          duration: const Duration(seconds: 2),
          backgroundColor: WhatsAppCallTheme.bar,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Envoi échoué : $e')),
      );
    }
  }

  Future<void> _reset() async {
    if (_myId.isEmpty) {
      setState(() => _topIndex = 0);
      return;
    }
    setState(() {
      _topIndex = 0;
      _feedLoading = true;
    });
    final feed = await ProfileApi.fetchDiscoverFeed(myId: _myId);
    if (!mounted) return;
    setState(() {
      _profiles = feed;
      _feedLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WhatsAppCallTheme.scaffold,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                _DiscoverHeader(
                  expanded: _searchExpanded,
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  onTapPill: _expandSearch,
                  onSubmittedClose: _collapseSearch,
                  onChanged: _onSearchQueryChanged,
                ),
                Expanded(
                  child: _feedLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: WhatsAppCallTheme.accent),
                        )
                      : RefreshIndicator(
                          color: WhatsAppCallTheme.accent,
                          backgroundColor: WhatsAppCallTheme.bar,
                          // Pull down anywhere on the cards area to re-pull
                          // the Supabase feed (picks up freshly-uploaded
                          // discover photos / new users without restart).
                          onRefresh: _reset,
                          child: _topIndex >= _profiles.length
                              ? ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    SizedBox(
                                      height: MediaQuery.of(context)
                                              .size
                                              .height *
                                          0.6,
                                      child: _Empty(
                                          onReset: () => _reset()),
                                    ),
                                  ],
                                )
                              : _buildStack(),
                        ),
                ),
                // Spacer for the floating bottom nav.
                SizedBox(
                    height: 12 + MediaQuery.paddingOf(context).bottom + 64),
              ],
            ),
            // Tap-outside scrim to dismiss the search.
            if (_searchExpanded)
              Positioned.fill(
                top: 64, // start below the header so taps inside still hit the field
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
                top: 60,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          _cardSize = Size(constraints.maxWidth, constraints.maxHeight);
          final w = _cardSize.width;
          final rotation = w == 0 ? 0.0 : (_drag.dx / w) * 0.25;
          return Stack(
            alignment: Alignment.center,
            children: [
              // Up to 2 background cards, drawn first (bottom of z-order).
              for (int depth = 2; depth >= 1; depth--)
                if (_topIndex + depth < _profiles.length)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: Offset(0, depth * 14.0),
                      child: Transform.scale(
                        scale: 1 - depth * 0.05,
                        child: IgnorePointer(
                          child: _ProfileCard(
                            profile: _profiles[_topIndex + depth],
                            onAdd: () {},
                          ),
                        ),
                      ),
                    ),
                  ),
              // Top card — draggable horizontally. GestureDetector wraps the
              // Transform-displaced card so the hit area follows the visual.
              Positioned.fill(
                child: Transform.translate(
                  offset: _drag,
                  child: Transform.rotate(
                    angle: rotation,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: _onPanStart,
                      onPanUpdate: _onPanUpdate,
                      onPanEnd: _onPanEnd,
                      child: _ProfileCard(
                        profile: _profiles[_topIndex],
                        onAdd: () {
                          _sendHello(_profiles[_topIndex]);
                          _advance();
                        },
                        onBack: _topIndex > 0 ? _back : null,
                        liked: _likedIds.contains(_profiles[_topIndex].id),
                        onToggleLike: () =>
                            _toggleLikeOnProfile(_profiles[_topIndex].id),
                      ),
                    ),
                  ),
                ),
              ),
            ],
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Text(
            AppStrings.t('discover_title'),
            style: const TextStyle(
              color: WhatsAppCallTheme.strongText,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          // Search pill: compact button when collapsed, wider TextField
          // when expanded — but never full-width.
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            width: expanded ? 200 : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: WhatsAppCallTheme.bar,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              children: [
                const Icon(Icons.search,
                    size: 16, color: WhatsAppCallTheme.subtleText),
                const SizedBox(width: 6),
                if (expanded)
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: onChanged,
                      textInputAction: TextInputAction.search,
                      cursorColor: WhatsAppCallTheme.accent,
                      style: const TextStyle(
                        color: WhatsAppCallTheme.strongText,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: AppStrings.t('search_friend_hint'),
                        hintStyle: const TextStyle(
                          color: WhatsAppCallTheme.subtleText,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
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
                        color: WhatsAppCallTheme.subtleText,
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
                      child: Icon(Icons.close,
                          size: 16, color: WhatsAppCallTheme.subtleText),
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
      color: WhatsAppCallTheme.bar,
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
          style: const TextStyle(
              color: WhatsAppCallTheme.subtleText, fontSize: 13),
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
                color: WhatsAppCallTheme.accent, strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Aucun profil pour « $query ».',
          style: const TextStyle(
              color: WhatsAppCallTheme.subtleText, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: results.length,
      separatorBuilder: (_, _) => Divider(
        color: Colors.white.withValues(alpha: 0.06),
        height: 1,
      ),
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
                      color: WhatsAppCallTheme.strongText,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (profile.handle.isNotEmpty)
                    Text(
                      '@${profile.handle}',
                      style: const TextStyle(
                        color: WhatsAppCallTheme.subtleText,
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
            color: WhatsAppCallTheme.accent);
      case FriendshipStatus.pendingOutgoing:
        return _StatusPill(
            label: AppStrings.t('friendship_sent'), color: Colors.amber);
      case FriendshipStatus.pendingIncoming:
        return _StatusPill(
            label: AppStrings.t('friendship_pending_in'),
            color: Colors.amber);
      case FriendshipStatus.rejected:
      case FriendshipStatus.none:
        return Material(
          color: WhatsAppCallTheme.accent,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onAdd,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 7),
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
            color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.onAdd,
    this.onBack,
    this.liked = false,
    this.onToggleLike,
  });

  final RemoteProfile profile;
  final VoidCallback onAdd;
  /// When non-null, a circular back arrow is rendered at the top-left of the
  /// card. Tapping it returns to the previous profile.
  final VoidCallback? onBack;
  final bool liked;
  /// When non-null, a heart button is rendered to the right of "Envoyer 👋".
  /// Tap toggles liked state.
  final VoidCallback? onToggleLike;

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(profile.language);
    final flag = lang?.flag ?? '';
    final photoUrl = profile.discoverPhotoUrl.isNotEmpty
        ? profile.discoverPhotoUrl
        : profile.avatarUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: WhatsAppCallTheme.bar),
          if (photoUrl.isNotEmpty)
            Image.network(
              photoUrl,
              fit: BoxFit.cover,
              // Centre crop — keeps the face roughly in the middle of the
              // card whether the source is portrait, square, or landscape.
              alignment: Alignment.center,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
          if (onBack != null)
            Positioned(
              top: 14,
              left: 14,
              child: _BackButton(onTap: onBack!),
            ),
          Positioned(
            left: 22,
            right: 22,
            bottom: 22,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        profile.displayName.isEmpty
                            ? '—'
                            : profile.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    if (flag.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(flag, style: const TextStyle(fontSize: 22)),
                      ),
                    ],
                  ],
                ),
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
                Row(
                  children: [
                    _AddButton(onTap: onAdd),
                    if (onToggleLike != null) ...[
                      const Spacer(),
                      _LikeHeart(liked: liked, onTap: onToggleLike!),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LikeHeart extends StatelessWidget {
  const _LikeHeart({required this.liked, required this.onTap});
  final bool liked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF3B5C);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: liked
              ? red.withValues(alpha: 0.18)
              : Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: liked ? red : Colors.white.withValues(alpha: 0.20),
            width: liked ? 2 : 1,
          ),
        ),
        child: Icon(
          liked ? Icons.favorite : Icons.favorite_border,
          size: liked ? 26 : 22,
          color: liked ? red : Colors.white,
        ),
      ),
    );
  }
}

/// "Envoyer 👋" — the emoji scales up briefly and the device gives a short
/// haptic tap on press. Parent then advances to the next card.
class _AddButton extends StatefulWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _rotate;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    // Scale: 1 → 1.7 → 1, with overshoot.
    _scale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.7)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 40),
      TweenSequenceItem(
          tween: Tween(begin: 1.7, end: 1.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 60),
    ]).animate(_ctrl);
    // Wave: -15° → +15° → -10° → 0 over the burst.
    _rotate = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -0.26), weight: 25),
      TweenSequenceItem(tween: Tween(begin: -0.26, end: 0.26), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 0.26, end: -0.17), weight: 25),
      TweenSequenceItem(tween: Tween(begin: -0.17, end: 0.0), weight: 25),
    ]).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onPress() {
    HapticFeedback.mediumImpact();
    _ctrl.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WhatsAppCallTheme.accent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _onPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Strip the 👋 from the i18n string so we can animate it on
              // its own next to the localised verb.
              Text(
                '${AppStrings.t('send_emoji').replaceAll('👋', '').trim()} ',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, _) => Transform.rotate(
                  angle: _rotate.value,
                  child: Transform.scale(
                    scale: _scale.value,
                    child: const Text('👋', style: TextStyle(fontSize: 16)),
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

/// "Rewind" button — top-left of the top card. Curved U-turn arrow,
/// styled like the Chercher / Filtres pills in the header (same gray
/// background, same height). Shown only when there's a previous profile.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WhatsAppCallTheme.bar,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Icon(
            Icons.replay,
            size: 18,
            color: WhatsAppCallTheme.subtleText,
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: WhatsAppCallTheme.bar,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.favorite_border,
                  color: WhatsAppCallTheme.subtleText, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('discover_done'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.refresh, color: WhatsAppCallTheme.accent),
              label: Text(
                AppStrings.t('restart'),
                style: const TextStyle(color: WhatsAppCallTheme.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
