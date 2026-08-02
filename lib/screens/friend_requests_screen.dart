import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friend_request_unread.dart';
import '../services/friendship_api.dart';
import '../services/like_api.dart';
import '../services/match_celebration.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/received_activity_unread.dart';
import '../services/supabase_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/appear.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/list_panel.dart';
import '../widgets/match_overlay.dart';
import '../widgets/profile_avatar.dart';
import 'chat_thread_screen.dart';
import 'profile_screen.dart';

/// A reaction entry rendered on the Demandes feed — the chat message
/// that was an emoji from [ChatApi.photoReactionEmojis], hydrated with
/// the reacting user's profile.
class _PhotoReaction {
  const _PhotoReaction({required this.message, this.author});
  final ChatMessage message;
  final RemoteProfile? author;
}

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
  List<_PhotoReaction> _reactions = const [];
  // Profiles who liked one of my photos, newest first.
  List<RemoteProfile> _likers = const [];
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
        _reactions = const [];
        _likers = const [];
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
      // Only show likes / reactions received since the feature went live, so
      // stale historical activity (e.g. an old like on a now-deleted photo)
      // never surfaces here.
      final since = ReceivedActivityUnread.featureStartAt;
      final likers = await LikeApi.fetchLikersSince(_myId, since);
      final reactionMessages = (await ChatApi.fetchPhotoReactions(_myId))
          .where((m) => m.createdAt.toUtc().isAfter(since))
          .toList(growable: false);
      // Hydrate each reaction with the author's profile so we can
      // render avatar + name. fetchByIds dedupes ids internally.
      final authorIds = reactionMessages
          .map((m) => m.senderId)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final authors = authorIds.isEmpty
          ? const <RemoteProfile>[]
          : await ProfileApi.fetchByIds(authorIds);
      final byId = {for (final p in authors) p.id: p};
      final reactions = [
        for (final m in reactionMessages)
          _PhotoReaction(message: m, author: byId[m.senderId]),
      ];
      if (!mounted) return;
      setState(() {
        _requests = friendships;
        _likers = likers;
        _reactions = reactions;
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
      // Same dark grey as the ListPanel, now filling the whole page —
      // no more pure black behind the header / footer.
      backgroundColor: SC.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(AppStrings.t('demandes_title'), style: SCText.h1),
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  /// Hairline divider between sections on the white block — inset past the
  /// avatar on the left, stopping before the action cluster on the right.
  static Widget get _rowDivider => Divider(
        height: 1,
        thickness: 1,
        indent: 70,
        endIndent: 24,
        color: Colors.white.withValues(alpha: 0.08),
      );

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: SC.accent));
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
    // Every category flattened into one list of rows, laid on the single white
    // block (same panel as the Messages page), in priority order: incoming
    // likes (need a decision) → photo likes → reactions. A hairline divider
    // falls between consecutive rows.
    final rows = <Widget>[
      for (final req in _requests)
        _RequestRow(
          request: req,
          onTap: () {
            final p = req.requester;
            if (p != null) _openProfile(p);
          },
          onAccept: () => _accept(req),
          onReject: () => _reject(req),
        ),
      for (final p in _likers)
        _LikeRow(liker: p, onTap: () => _openProfile(p)),
      for (final r in _reactions)
        _ReactionRow(
          reaction: r,
          onTap: () {
            final a = r.author;
            if (a != null) _openProfile(a);
          },
        ),
    ];
    // Same as the Messages page: the panel lives inside the page scroll view
    // so the WHOLE panel moves when you scroll, with a min-height = the zone so
    // it fills and rests flush on the nav at rest (the concave notches hug its
    // rounded bottom corners, Discover-style).
    final navBody = GlassNavBar.totalReservedHeight + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fill = constraints.maxHeight - 26 - navBody;
        return RefreshIndicator(
          color: SC.accent,
          backgroundColor: SC.menu,
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: 26, bottom: navBody),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: fill > 0 ? fill : 0),
                child: ListPanel(
                  child: rows.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 44),
                          child: _NoRequestsEmpty(),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (i, row) in rows.indexed)
                              // Rows ease in (fade + slide) in a quick cascade.
                              FadeSlideIn(
                                delay: Duration(milliseconds: i * 55),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (i > 0) _rowDivider,
                                    row,
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.request,
    required this.onTap,
    required this.onAccept,
    required this.onReject,
  });

  final IncomingFriendRequest request;
  final VoidCallback onTap;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final p = request.requester;
    final name = p?.displayName.isNotEmpty == true
        ? p!.displayName
        : (p?.handle.isNotEmpty == true
              ? '@${p!.handle}'
              : AppStrings.t('chat_no_name'));
    final subtitle = AppStrings.t(
      'demandes_wants_to_match',
      args: {'name': name},
    );

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              ProfileAvatar(
                displayName: p?.displayName ?? '',
                avatarUrl: p?.avatarUrl,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SCText.body.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _AcceptButton(onTap: onAccept),
              const SizedBox(width: 6),
              _RejectButton(onTap: onReject),
            ],
          ),
        ),
      ),
    );
  }
}

/// Read-only row used to surface a Discover-rail emoji reaction sent to
/// the local user. No accept / reject — tapping the row just opens the
/// reacting peer's profile, same as on the Messages list.
class _ReactionRow extends StatelessWidget {
  const _ReactionRow({required this.reaction, required this.onTap});

  final _PhotoReaction reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = reaction.author;
    final name = p?.displayName.isNotEmpty == true
        ? p!.displayName
        : (p?.handle.isNotEmpty == true
              ? '@${p!.handle}'
              : AppStrings.t('chat_no_name'));
    final subtitle = AppStrings.t(
      'demandes_reacted_to_photo',
      args: {'name': name},
    );

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              ProfileAvatar(
                displayName: p?.displayName ?? '',
                avatarUrl: p?.avatarUrl,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SCText.body.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _PopInEmoji(id: reaction.message.id, emoji: reaction.message.body),
            ],
          ),
        ),
      ),
    );
  }
}

/// A "X liked your photo ❤" row on the Demandes feed — mirrors
/// [_ReactionRow] but for the heart-like sent on a Discover photo card.
class _LikeRow extends StatelessWidget {
  const _LikeRow({required this.liker, required this.onTap});

  final RemoteProfile liker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = liker.displayName.isNotEmpty
        ? liker.displayName
        : (liker.handle.isNotEmpty
              ? '@${liker.handle}'
              : AppStrings.t('chat_no_name'));
    final subtitle = AppStrings.t(
      'demandes_liked_your_photo',
      args: {'name': name},
    );

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              ProfileAvatar(
                displayName: liker.displayName,
                avatarUrl: liker.avatarUrl,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SCText.body.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _PopInEmoji(id: 'like_${liker.id}', emoji: '❤', fontSize: 24),
            ],
          ),
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
            AppStrings.t('match_cta'),
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
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(Icons.close_rounded, color: SC.textMuted, size: 22),
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
              child: const Icon(
                Icons.group_outlined,
                color: SC.accent,
                size: 34,
              ),
            ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('demandes_empty_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('demandes_empty_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
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
