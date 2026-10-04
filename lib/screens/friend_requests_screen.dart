import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/device_id.dart';
import '../services/friend_request_unread.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/match_celebration.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/supabase_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/appear.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/likes_lock.dart';
import '../widgets/match_overlay.dart';
import '../widgets/profile_avatar.dart';
import 'chat_thread_screen.dart';
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
  List<IncomingFriendRequest> _requests = const [];
  // Profiles who liked one of my photos, newest first.
  LikesLock? _lock;
  bool _loading = true;
  String? _error;
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
      if (!mounted) return;
      setState(() {
        _requests = friendships;
        _lock = lock;
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
    final next = _requests
        .where((r) => r.friendship.id != req.friendship.id)
        .toList();
    setState(() => _requests = next);
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
    final next = _requests
        .where((r) => r.friendship.id != req.friendship.id)
        .toList();
    setState(() => _requests = next);
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

  void _openProfile(RemoteProfile peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: peer.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.tabBg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('demandes_title'),
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
                      // Rose et blanc, comme le coeur de Discover.
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFF7D97), Color(0xFFE8385F)],
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.favorite_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_requests.length}',
                            style: const TextStyle(
                              color: Colors.white,
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
        _RequestTile(
          request: req,
          revealed: revealed(req.requester),
          onOpenProfile: () => openOrUnlock(req.requester),
          onAccept: () => _accept(req),
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
              children: const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 80),
                  child: _NoRequestsEmpty(),
                ),
              ],
            )
          : GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(16, 4, 16, navBody + 8),
              // Des carres : la premiere photo de la galerie de chaque personne.
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1,
              ),
              itemCount: rows.length,
              // Rows ease in (fade + slide) in a quick cascade.
              itemBuilder: (context, i) => FadeSlideIn(
                delay: Duration(milliseconds: i * 55),
                child: rows[i],
              ),
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
  });

  final IncomingFriendRequest request;
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

    return GestureDetector(
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
      child: InkWell(
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

class _NoRequestsEmpty extends StatelessWidget {
  const _NoRequestsEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Breathing(
              child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: SC.accent.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(color: SC.accent.withValues(alpha: 0.35)),
              ),
              child: Icon(
                Icons.group_outlined,
                color: SC.accentFg,
                size: 34,
              ),
            ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('demandes_empty_title'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('demandes_empty_body'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
