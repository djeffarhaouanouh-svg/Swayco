import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';

class IncomingFriendRequest {
  const IncomingFriendRequest({required this.friendship, this.requester});
  final Friendship friendship;
  final RemoteProfile? requester;
}

enum FriendshipStatus { none, pendingOutgoing, pendingIncoming, accepted, rejected }

class FriendshipCounts {
  const FriendshipCounts({required this.followers, required this.following});
  final int followers;
  final int following;
}

enum FriendDirection { followers, following }

class Friendship {
  const Friendship({
    required this.id,
    required this.requester,
    required this.addressee,
    required this.status,
  });

  final String id;
  final String requester;
  final String addressee;
  final String status;

  factory Friendship.fromMap(Map<String, dynamic> m) => Friendship(
        id: m['id']?.toString() ?? '',
        requester: m['requester']?.toString() ?? '',
        addressee: m['addressee']?.toString() ?? '',
        status: m['status']?.toString() ?? 'pending',
      );

  /// The "other side" of the relation from [meId]'s perspective.
  String peerOf(String meId) => requester == meId ? addressee : requester;
}

abstract final class FriendshipApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Realtime listener for friendship rows that involve [userId] (either
  /// as requester or addressee). Fires on every INSERT/UPDATE so the
  /// caller can refresh their friend list / incoming-requests inbox
  /// without waiting for a tab open or app resume. Returns the channel
  /// so callers can `removeChannel` it on dispose.
  static RealtimeChannel subscribeMine({
    required String userId,
    required void Function() onChange,
  }) {
    final channel = _c
        .channel('friendships:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'friendships',
          callback: (payload) {
            // The filter is server-side via the .or below would only
            // accept one column per filter. Easier to re-fetch on every
            // friendship change and let RLS filter what we can see.
            onChange();
          },
        );
    channel.subscribe();
    return channel;
  }

  /// Pending invitations addressed TO me, hydrated with the requester's
  /// profile so the UI can render avatar + name without a second query.
  static Future<List<IncomingFriendRequest>> fetchIncomingPendingWithProfiles(
    String meId,
  ) async {
    if (!isSupabaseReady || meId.isEmpty) return const [];
    final rows = await _c
        .from('friendships')
        .select()
        .eq('addressee', meId)
        .eq('status', 'pending');
    final friendships = (rows as List)
        .map((r) => Friendship.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
    if (friendships.isEmpty) return const [];

    final requesterIds = friendships
        .map((f) => f.requester)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final profiles = await ProfileApi.fetchByIds(requesterIds);
    final byId = {for (final p in profiles) p.id: p};
    return [
      for (final f in friendships)
        IncomingFriendRequest(friendship: f, requester: byId[f.requester]),
    ];
  }

  /// Accepted friends, hydrated with profile rows. Direction picks which
  /// side of the relation [meId] is on:
  /// - followers  → people who sent ME a request that I accepted.
  /// - following  → people I sent a request to and they accepted.
  ///
  /// Uses the `friendship_accepted_peers` SECURITY DEFINER RPC to get the
  /// peer ids (so the result is correct even under restrictive RLS on
  /// `friendships`), then hydrates them via `profiles`.
  static Future<List<RemoteProfile>> fetchAcceptedPeers({
    required String meId,
    required FriendDirection direction,
  }) async {
    if (!isSupabaseReady || meId.isEmpty) return const [];
    try {
      final result = await _c.rpc(
        'friendship_accepted_peers',
        params: {
          'p_user_id': meId,
          'p_direction':
              direction == FriendDirection.followers ? 'followers' : 'following',
        },
      );
      if (result is! List) return const [];
      final peerIds = result
          .map((r) => Map<String, dynamic>.from(r as Map)['peer_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (peerIds.isEmpty) return const [];
      return ProfileApi.fetchByIds(peerIds);
    } catch (e) {
      debugPrint('FriendshipApi.fetchAcceptedPeers failed: $e');
      return const [];
    }
  }

  /// Counts for the profile screen.
  /// - `followers`  = accepted friendships where the user is the addressee.
  /// - `following`  = accepted friendships where the user is the requester.
  ///
  /// Delegates to the `friendship_counts` SECURITY DEFINER RPC so the
  /// numbers are correct even when viewing someone else's profile under a
  /// restrictive RLS policy. The RPC returns aggregates only (no row data
  /// leaks), so it's safe to expose.
  static Future<FriendshipCounts> countsFor(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) {
      return const FriendshipCounts(followers: 0, following: 0);
    }
    try {
      final result = await _c.rpc(
        'friendship_counts',
        params: {'p_user_id': userId},
      );
      // The function `returns table(...)` so Supabase serialises it as a
      // list of one row. Accept either shape defensively.
      final Map<String, dynamic> row;
      if (result is List && result.isNotEmpty) {
        row = Map<String, dynamic>.from(result.first as Map);
      } else if (result is Map) {
        row = Map<String, dynamic>.from(result);
      } else {
        return const FriendshipCounts(followers: 0, following: 0);
      }
      return FriendshipCounts(
        followers: (row['followers'] as num?)?.toInt() ?? 0,
        following: (row['following'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('FriendshipApi.countsFor failed: $e');
      return const FriendshipCounts(followers: 0, following: 0);
    }
  }

  /// Fetch every friendship row involving [meId] in either direction.
  static Future<List<Friendship>> fetchMine(String meId) async {
    if (!isSupabaseReady || meId.isEmpty) return const [];
    final rows = await _c
        .from('friendships')
        .select()
        .or('requester.eq.$meId,addressee.eq.$meId');
    return (rows as List)
        .map((r) => Friendship.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// Send a friend request from [meId] to [peerId]. Lands as `pending`
  /// so the addressee must explicitly accept it from the Demandes page
  /// before the two sides become friends. If a reverse row already
  /// exists in `pending`, it stays pending — both sides can decide
  /// independently.
  ///
  /// Idempotent: if a same-direction row already exists, it's returned
  /// as-is.
  static Future<Friendship?> sendRequest({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady) return null;
    if (meId.isEmpty || peerId.isEmpty || meId == peerId) return null;

    // 1. Same-direction row → idempotent.
    final sameDir = await _c
        .from('friendships')
        .select()
        .eq('requester', meId)
        .eq('addressee', peerId)
        .limit(1)
        .maybeSingle();
    if (sameDir != null) {
      return Friendship.fromMap(Map<String, dynamic>.from(sameDir));
    }

    final inserted = await _c
        .from('friendships')
        .insert({
          'requester': meId,
          'addressee': peerId,
          'status': 'pending',
        })
        .select()
        .single();
    // Fire-and-forget push: peer gets a "X veut être ami" notif. Best
    // effort — never block the friendship insert on the dispatch call.
    unawaited(_notifyNewFollower(meId, peerId));
    return Friendship.fromMap(Map<String, dynamic>.from(inserted));
  }

  static Future<void> _notifyNewFollower(String meId, String peerId) async {
    if (!isSupabaseReady) return;
    try {
      final myProfile = await ProfileApi.fetchById(meId);
      final myName = myProfile?.displayName.trim() ?? '';
      await PushDispatcher.notify(
        recipientUid: peerId,
        title: myName.isEmpty ? 'Nouvelle demande' : myName,
        body: 'veut être ami',
        type: 'friend_request',
        data: {'requesterId': meId},
      );
    } catch (e) {
      debugPrint('friendship notify failed: $e');
    }
  }

  static Future<void> accept(String friendshipId) async {
    if (!isSupabaseReady) return;
    await _c.from('friendships').update({
      'status': 'accepted',
      'responded_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', friendshipId);
  }

  static Future<void> reject(String friendshipId) async {
    if (!isSupabaseReady) return;
    await _c.from('friendships').update({
      'status': 'rejected',
      'responded_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', friendshipId);
  }

  static Future<void> remove(String friendshipId) async {
    if (!isSupabaseReady) return;
    await _c.from('friendships').delete().eq('id', friendshipId);
  }

  /// Unfollow [peerId]: delete the friendship edge I created when I
  /// followed them (requester = me, addressee = peer). The reverse edge,
  /// if any (they still follow me), is left intact — unfollowing is a
  /// one-directional action, like Instagram. Idempotent: deleting a row
  /// that doesn't exist is a no-op.
  static Future<void> unfollow({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || meId.isEmpty || peerId.isEmpty) return;
    await _c
        .from('friendships')
        .delete()
        .eq('requester', meId)
        .eq('addressee', peerId);
  }

  /// Viewer-mode helper for the profile screen: resolves the two
  /// independent directions of the relation between me ([meId]) and a
  /// [peerId]. `peerFollowsMe` is true when the peer sent me a request
  /// (their row: requester = peer, addressee = me); `iFollowPeer` is true
  /// when I sent them one. Both can be true (mutual) or false (strangers).
  static Future<({bool peerFollowsMe, bool iFollowPeer})> directionalWith({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || meId.isEmpty || peerId.isEmpty || meId == peerId) {
      return (peerFollowsMe: false, iFollowPeer: false);
    }
    try {
      final mine = await fetchMine(meId);
      var peerFollowsMe = false;
      var iFollowPeer = false;
      for (final f in mine) {
        if (f.status != 'accepted') continue;
        if (f.requester == peerId && f.addressee == meId) peerFollowsMe = true;
        if (f.requester == meId && f.addressee == peerId) iFollowPeer = true;
      }
      return (peerFollowsMe: peerFollowsMe, iFollowPeer: iFollowPeer);
    } catch (e) {
      debugPrint('FriendshipApi.directionalWith failed: $e');
      return (peerFollowsMe: false, iFollowPeer: false);
    }
  }

  /// Derive how I (`meId`) currently stand with [peerId] given a list of my
  /// friendships. Useful for tagging each search result with a status pill.
  static (FriendshipStatus, Friendship?) statusWith(
    String meId,
    String peerId,
    List<Friendship> mine,
  ) {
    for (final f in mine) {
      final involvesPeer =
          (f.requester == meId && f.addressee == peerId) ||
              (f.requester == peerId && f.addressee == meId);
      if (!involvesPeer) continue;
      switch (f.status) {
        case 'accepted':
          return (FriendshipStatus.accepted, f);
        case 'rejected':
          return (FriendshipStatus.rejected, f);
        case 'pending':
          if (f.requester == meId) {
            return (FriendshipStatus.pendingOutgoing, f);
          }
          return (FriendshipStatus.pendingIncoming, f);
      }
    }
    return (FriendshipStatus.none, null);
  }
}
