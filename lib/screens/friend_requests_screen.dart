import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
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
      final rows =
          await FriendshipApi.fetchIncomingPendingWithProfiles(_myId);
      if (!mounted) return;
      setState(() {
        _requests = rows;
        _loading = false;
      });
      FriendRequestUnread.setCount(rows.length);
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
    if (_requests.isEmpty) {
      return const _NoRequestsEmpty();
    }
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
              decoration: const BoxDecoration(
                color: SC.bubbleIn,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.group_outlined,
                color: SC.textMuted,
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
