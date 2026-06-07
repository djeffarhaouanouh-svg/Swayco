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
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/received_activity_unread.dart';
import '../services/supabase_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

/// A reaction entry rendered on the Demandes feed — the chat message
/// that was an emoji from [ChatApi.photoReactionEmojis], hydrated with
/// the reacting user's profile.
class _PhotoReaction {
  const _PhotoReaction({required this.message, this.author});
  final ChatMessage message;
  final RemoteProfile? author;
}

/// Demandes — incoming pending friend requests. Each row exposes
/// Accepter / Refuser actions; accepted requests disappear (they
/// become regular friendships and surface on the Chat list).
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
  // People who follow me but I don't follow back yet — surfaced here with a
  // "S'abonner en retour" button so the relation can be made mutual.
  List<RemoteProfile> _newFollowers = const [];
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
        _newFollowers = const [];
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
      // People who follow me (accepted, I'm the addressee) but I haven't
      // followed back yet (no accepted row where I'm the requester). These
      // get a "S'abonner en retour" button below.
      final newFollowers = await _fetchFollowBackCandidates();
      if (!mounted) return;
      setState(() {
        _requests = friendships;
        _likers = likers;
        _reactions = reactions;
        _newFollowers = newFollowers;
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

  /// Resolve the people who follow me but I don't follow back. Reads all my
  /// friendship edges once and diffs the two accepted directions. Returns an
  /// empty list (never throws) so a hiccup here can't blank the whole page.
  Future<List<RemoteProfile>> _fetchFollowBackCandidates() async {
    try {
      final mine = await FriendshipApi.fetchMine(_myId);
      final iFollow = <String>{}; // accepted edges where I'm the requester
      final followMe = <String>{}; // accepted edges where I'm the addressee
      for (final f in mine) {
        if (f.status != 'accepted') continue;
        if (f.requester == _myId) iFollow.add(f.addressee);
        if (f.addressee == _myId) followMe.add(f.requester);
      }
      final ids = followMe
          .where((id) => id.isNotEmpty && id != _myId && !iFollow.contains(id))
          .toList(growable: false);
      if (ids.isEmpty) return const [];
      return await ProfileApi.fetchByIds(ids);
    } catch (_) {
      return const [];
    }
  }

  /// "S'abonner en retour": follow back instantly (accepted edge, no approval).
  /// Optimistically drops the row; restores it on failure.
  Future<void> _followBack(RemoteProfile peer) async {
    final next = _newFollowers.where((p) => p.id != peer.id).toList();
    setState(() => _newFollowers = next);
    try {
      await FriendshipApi.follow(meId: _myId, peerId: peer.id);
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'requests', 'kind': 'follow'},
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _newFollowers = [..._newFollowers, peer]);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _accept(IncomingFriendRequest req) async {
    final next = _requests
        .where((r) => r.friendship.id != req.friendship.id)
        .toList();
    setState(() => _requests = next);
    FriendRequestUnread.setCount(next.length);
    try {
      await FriendshipApi.accept(req.friendship.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _requests = [..._requests, req]);
      FriendRequestUnread.setCount(_requests.length);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
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
      backgroundColor: const Color(0xFF0E0E0E),
      body: ColoredBox(
        color: const Color(0xFF0E0E0E),
        child: SafeArea(
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
      ),
    );
  }

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
    // One glass card per non-empty category, in priority order: pending
    // requests (need a decision) → new followers (follow back) → likes →
    // reactions. Built as a list so the 18px gaps fall only between cards.
    final sections = <Widget>[
      if (_requests.isNotEmpty)
        GlassContainer(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
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
            ],
          ),
        ),
      if (_newFollowers.isNotEmpty)
        GlassContainer(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              for (final p in _newFollowers)
                _FollowBackRow(
                  follower: p,
                  onTap: () => _openProfile(p),
                  onFollowBack: () => _followBack(p),
                ),
            ],
          ),
        ),
      // Likes received on my photos.
      if (_likers.isNotEmpty)
        GlassContainer(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              for (final p in _likers)
                _LikeRow(liker: p, onTap: () => _openProfile(p)),
            ],
          ),
        ),
      if (_reactions.isNotEmpty)
        GlassContainer(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              for (final r in _reactions)
                _ReactionRow(
                  reaction: r,
                  onTap: () {
                    final a = r.author;
                    if (a != null) _openProfile(a);
                  },
                ),
            ],
          ),
        ),
    ];
    return RefreshIndicator(
      color: SC.accent,
      backgroundColor: SC.bubbleIn,
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        // Clear the floating nav bar so the last row stays reachable.
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          84 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // Empty state still gets the glass frame so the page never
          // feels like a void — same surface the populated list uses
          // (with the stronger glass shade so it doesn't read as a
          // dark void on the mesh) and the centered copy inside.
          if (sections.isEmpty)
            GlassContainer(
              borderRadius: BorderRadius.circular(24),
              color: SC.glassStrong,
              border: SC.glassBorderStrong,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
              child: const _NoRequestsEmpty(),
            ),
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 18),
            sections[i],
          ],
        ],
      ),
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
      'demandes_wants_to_be_friend',
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
                avatarColorHex: p?.avatarColor,
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

/// "X s'est abonné·e à toi" row — the peer follows me and I don't follow
/// back yet. One "S'abonner en retour" button makes the relation mutual;
/// tapping the rest of the row opens their profile.
class _FollowBackRow extends StatelessWidget {
  const _FollowBackRow({
    required this.follower,
    required this.onTap,
    required this.onFollowBack,
  });

  final RemoteProfile follower;
  final VoidCallback onTap;
  final VoidCallback onFollowBack;

  @override
  Widget build(BuildContext context) {
    final name = follower.displayName.isNotEmpty
        ? follower.displayName
        : (follower.handle.isNotEmpty
              ? '@${follower.handle}'
              : AppStrings.t('chat_no_name'));
    final subtitle = AppStrings.t(
      'demandes_started_following',
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
                displayName: follower.displayName,
                avatarUrl: follower.avatarUrl,
                avatarColorHex: follower.avatarColor,
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
              _FollowBackButton(onTap: onFollowBack),
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
                avatarColorHex: p?.avatarColor,
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
              Text(reaction.message.body, style: const TextStyle(fontSize: 26)),
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
                avatarColorHex: liker.avatarColor,
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
              const Text('❤', style: TextStyle(fontSize: 24)),
            ],
          ),
        ),
      ),
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
            AppStrings.t('accept'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Accent pill that follows the peer back. Same shape as [_AcceptButton]
/// but carries the "S'abonner en retour" label.
class _FollowBackButton extends StatelessWidget {
  const _FollowBackButton({required this.onTap});
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
            AppStrings.t('follow_back'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
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
            Container(
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
