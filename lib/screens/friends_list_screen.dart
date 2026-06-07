import 'dart:async';

import 'package:flutter/material.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
import '../services/profile_api.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

/// List of accounts behind the Followers / Following counts on ProfileScreen.
/// Each row shows the peer's avatar + name + language. When viewing
/// followers, a "S'abonner" button appears for anyone the user does not
/// already follow back, so the relation can be made mutual in one tap.
class FriendsListScreen extends StatefulWidget {
  const FriendsListScreen({
    super.key,
    required this.direction,
    this.userId,
  });

  final FriendDirection direction;

  /// When set, list the followers / following of THIS user instead of
  /// the local user. Used when opening the screen from someone else's
  /// profile so tapping their follower count actually shows their
  /// followers, not yours. Null â†’ defaults to the device's own id.
  final String? userId;

  @override
  State<FriendsListScreen> createState() => _FriendsListScreenState();
}

class _FriendsListScreenState extends State<FriendsListScreen> {
  String _myId = '';
  List<RemoteProfile> _peers = const [];
  Set<String> _myFollowingIds = const {};
  Set<String> _myFollowingPendingIds = const {};
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = WebPoll.every(
      const Duration(seconds: 12),
      () => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final myId = await DeviceId.getOrCreate();
      // The list itself is for whoever the screen was opened for â€”
      // the local user by default, or the peer when navigating from
      // someone else's profile.
      final targetId = widget.userId ?? myId;
      var peers = await FriendshipApi.fetchAcceptedPeers(
        meId: targetId,
        direction: widget.direction,
      );
      // On MY own lists, hide anyone who has blocked me — their edge with me
      // is dead on their side, so they shouldn't sit in my abonnés/abonnements.
      if (targetId == myId) {
        try {
          final blockers = await BlockApi.fetchMyBlockerIds();
          if (blockers.isNotEmpty) {
            peers =
                peers.where((p) => !blockers.contains(p.id)).toList(growable: false);
          }
        } catch (_) {}
      }
      // The "Follow / Following" affordance on each row is always
      // relative to the LOCAL user (so we can offer follow-back),
      // hence we still read MY edges below regardless of whose list
      // we render.
      final mine = await FriendshipApi.fetchMine(myId);
      final followingAccepted = <String>{};
      final followingPending = <String>{};
      for (final f in mine) {
        if (f.requester == myId) {
          if (f.status == 'accepted') {
            followingAccepted.add(f.addressee);
          } else if (f.status == 'pending') {
            followingPending.add(f.addressee);
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _myId = myId;
        _peers = peers;
        _myFollowingIds = followingAccepted;
        _myFollowingPendingIds = followingPending;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erreur de chargement : $e';
        _loading = false;
      });
    }
  }

  Future<void> _followBack(RemoteProfile peer) async {
    try {
      final f = await FriendshipApi.follow(meId: _myId, peerId: peer.id);
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'friends_list', 'kind': 'follow'},
      );
      if (!mounted) return;
      if (f == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Supabase non configurÃ©.")),
        );
        return;
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.direction == FriendDirection.followers
        ? AppStrings.t('profile_followers')
        : AppStrings.t('profile_following');
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E0E),
        surfaceTintColor: Colors.transparent,
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'RafraÃ®chir',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
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
          style: const TextStyle(color: Color(0xFFFFAB91), height: 1.35, fontSize: 13),
        ),
      );
    }
    if (_peers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            widget.direction == FriendDirection.followers
                ? 'Personne ne te suit encore.'
                : 'Tu ne suis personne encore.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: SC.textMuted, fontSize: 14),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _peers.length,
      itemBuilder: (ctx, i) {
        final p = _peers[i];
        final showFollowBack =
            widget.direction == FriendDirection.followers &&
                !_myFollowingIds.contains(p.id) &&
                !_myFollowingPendingIds.contains(p.id);
        final showPendingPill =
            widget.direction == FriendDirection.followers &&
                _myFollowingPendingIds.contains(p.id);
        return _FriendRow(
          profile: p,
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ProfileScreen(userId: p.id),
            ),
          ),
          trailing: showFollowBack
              ? _FollowBackButton(onTap: () => _followBack(p))
              : showPendingPill
                  ? const _MutedPill(label: 'En attente', icon: Icons.hourglass_top)
                  : const _MutedPill(label: 'Ami', icon: Icons.check_circle),
        );
      },
    );
  }
}

class _FriendRow extends StatelessWidget {
  const _FriendRow({
    required this.profile,
    required this.trailing,
    required this.onTap,
  });

  final RemoteProfile profile;
  final Widget trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(profile.language);
    final name = profile.displayName.isNotEmpty
        ? profile.displayName
        : (profile.handle.isNotEmpty ? '@${profile.handle}' : 'Sans nom');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 72,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  ProfileAvatar(
                    displayName: name,
                    avatarUrl: profile.avatarUrl,
                    avatarColorHex: profile.avatarColor,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: const TextStyle(
                            color: SC.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        if (lang != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${lang.flag}  ${lang.label}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: const TextStyle(
                              color: SC.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FollowBackButton extends StatelessWidget {
  const _FollowBackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.accent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_add_alt_1, size: 16, color: Colors.white),
              SizedBox(width: 6),
              Text(
                'S\'abonner',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MutedPill extends StatelessWidget {
  const _MutedPill({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF262626),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: SC.textMuted),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: SC.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
