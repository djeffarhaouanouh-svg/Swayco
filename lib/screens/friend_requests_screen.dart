import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friend_request_unread.dart';
import '../services/friendship_api.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/mesh_background.dart';
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
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final ch = _channel;
    if (ch != null) {
      Supabase.instance.client.removeChannel(ch);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload(silent: true);
  }

  Future<void> _bootstrap() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    await _reload();
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
      final friendships =
          await FriendshipApi.fetchIncomingPendingWithProfiles(_myId);
      final reactionMessages = await ChatApi.fetchPhotoReactions(_myId);
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

  Future<void> _accept(IncomingFriendRequest req) async {
    final next = _requests.where((r) => r.friendship.id != req.friendship.id).toList();
    setState(() => _requests = next);
    FriendRequestUnread.setCount(next.length);
    try {
      await FriendshipApi.accept(req.friendship.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _requests = [..._requests, req]);
      FriendRequestUnread.setCount(_requests.length);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _reject(IncomingFriendRequest req) async {
    final next = _requests.where((r) => r.friendship.id != req.friendship.id).toList();
    setState(() => _requests = next);
    FriendRequestUnread.setCount(next.length);
    try {
      await FriendshipApi.reject(req.friendship.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _requests = [..._requests, req]);
      FriendRequestUnread.setCount(_requests.length);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  void _openProfile(RemoteProfile peer) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(userId: peer.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      body: MeshBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    AppStrings.t('demandes_title'),
                    style: SCText.h1,
                  ),
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
      return const Center(
        child: CircularProgressIndicator(color: SC.accent),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error!,
          style: const TextStyle(
              color: Color(0xFFFFAB91), height: 1.35, fontSize: 13),
        ),
      );
    }
    final hasContent = _requests.isNotEmpty || _reactions.isNotEmpty;
    return RefreshIndicator(
      color: SC.accent,
      backgroundColor: SC.bubbleIn,
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        // Clear the floating nav bar so the last row stays reachable.
        padding: EdgeInsets.fromLTRB(
          16, 0, 16, 84 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // Empty state still gets the glass frame so the page never
          // feels like a void — same surface the populated list uses
          // (with the stronger glass shade so it doesn't read as a
          // dark void on the mesh) and the centered copy inside.
          if (!hasContent)
            GlassContainer(
              borderRadius: BorderRadius.circular(24),
              color: SC.glassStrong,
              border: SC.glassBorderStrong,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 28),
              child: const _NoRequestsEmpty(),
            ),
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
          if (_requests.isNotEmpty && _reactions.isNotEmpty)
            const SizedBox(height: 18),
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
    final handle = (p?.handle.isNotEmpty ?? false) ? '@${p!.handle}' : '';

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: SCText.name,
                    ),
                    if (handle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        handle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: SCText.preview,
                      ),
                    ],
                  ],
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
      args: {'name': name, 'emoji': reaction.message.body},
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
              Text(
                reaction.message.body,
                style: const TextStyle(fontSize: 26),
              ),
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
          child: Icon(
            Icons.close_rounded,
            color: SC.textMuted,
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
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: SC.accent.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(
                  color: SC.accent.withValues(alpha: 0.35),
                ),
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
