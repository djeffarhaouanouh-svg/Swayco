import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_strings.dart';
import 'profile_api.dart';
import 'push_dispatcher.dart';
import 'supabase_service.dart';

class IncomingFriendRequest {
  const IncomingFriendRequest({required this.friendship, this.requester});
  final Friendship friendship;
  final RemoteProfile? requester;
}

enum FriendshipStatus { none, pendingOutgoing, pendingIncoming, accepted, rejected }

enum FriendDirection { followers, following }

class Friendship {
  const Friendship({
    required this.id,
    required this.requester,
    required this.addressee,
    required this.status,
    this.matchedAt,
  });

  final String id;
  final String requester;
  final String addressee;
  final String status;

  /// When the two sides became a match (`responded_at`), falling back to when
  /// the like was sent. Drives the "newest match first" order of the bubbles.
  final DateTime? matchedAt;

  factory Friendship.fromMap(Map<String, dynamic> m) => Friendship(
        id: m['id']?.toString() ?? '',
        requester: m['requester']?.toString() ?? '',
        addressee: m['addressee']?.toString() ?? '',
        status: m['status']?.toString() ?? 'pending',
        matchedAt:
            DateTime.tryParse(
              (m['responded_at'] ?? m['created_at'] ?? '').toString(),
            )?.toUtc(),
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

  /// Like [peerId] — the Tinder move. Two outcomes:
  ///   * they had already liked me (a `pending` row the other way) → the two
  ///     likes meet, the row flips to `accepted` and it's a MATCH on the spot;
  ///   * nobody liked me yet → a `pending` row lands and they decide from the
  ///     Demandes page.
  ///
  /// There is no instant one-way follow any more: an accepted row always means
  /// both sides said yes. Idempotent — re-liking someone returns the existing
  /// state instead of duplicating a row.
  static Future<({Friendship? friendship, bool matched})> like({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady) return (friendship: null, matched: false);
    if (meId.isEmpty || peerId.isEmpty || meId == peerId) {
      return (friendship: null, matched: false);
    }

    // Guarantee my own `profiles` row exists first — the insert below FK-
    // references it (friendships_requester_fkey), and a boot-time sync
    // skipped on a flaky launch would otherwise crash with 23503.
    await ProfileApi.ensureMyProfileRow();

    // 1. They already liked me → accepting their row IS the match.
    final reverse = await _c
        .from('friendships')
        .select()
        .eq('requester', peerId)
        .eq('addressee', meId)
        .limit(1)
        .maybeSingle();
    if (reverse != null) {
      final theirs = Friendship.fromMap(Map<String, dynamic>.from(reverse));
      if (theirs.status == 'accepted') {
        return (friendship: theirs, matched: true);
      }
      final matched = await _promoteToMatch(theirs.id);
      unawaited(_notifyMatch(meId, peerId));
      return (friendship: matched ?? theirs, matched: true);
    }

    // 2. I already liked them → idempotent, still waiting on their answer.
    final sameDir = await _c
        .from('friendships')
        .select()
        .eq('requester', meId)
        .eq('addressee', peerId)
        .limit(1)
        .maybeSingle();
    if (sameDir != null) {
      final mine = Friendship.fromMap(Map<String, dynamic>.from(sameDir));
      return (friendship: mine, matched: mine.status == 'accepted');
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
    // Fire-and-forget push: peer gets a "X veut te matcher" notif. Best
    // effort — never block the insert on the dispatch call.
    unawaited(_notifyNewFollower(meId, peerId));
    return (
      friendship: Friendship.fromMap(Map<String, dynamic>.from(inserted)),
      matched: false,
    );
  }

  /// Flip a row to `accepted` (= matched) and return it.
  static Future<Friendship?> _promoteToMatch(String friendshipId) async {
    final row = await _c
        .from('friendships')
        .update({
          'status': 'accepted',
          'responded_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', friendshipId)
        .select()
        .maybeSingle();
    if (row == null) return null;
    return Friendship.fromMap(Map<String, dynamic>.from(row));
  }

  /// My matches, newest first — the order the Messages page shows the match
  /// bubbles in. Reads my own rows (so the timestamps come along) instead of
  /// the peers RPC, then hydrates the profiles in that order.
  ///
  /// [matchedAt] rides along because the bubble rail keeps a match for a fixed
  /// window after it happened, not until the first message.
  static Future<List<({RemoteProfile profile, DateTime? matchedAt})>>
      fetchMatchesNewestFirst(String meId) async {
    if (!isSupabaseReady || meId.isEmpty) return const [];
    try {
      final mine = await fetchMine(meId);
      final accepted = mine.where((f) => f.status == 'accepted').toList()
        ..sort((a, b) {
          final ta = a.matchedAt;
          final tb = b.matchedAt;
          if (ta == null && tb == null) return 0;
          if (ta == null) return 1;
          if (tb == null) return -1;
          return tb.compareTo(ta);
        });
      final ids = <String>[];
      final timeById = <String, DateTime?>{};
      for (final f in accepted) {
        final peer = f.peerOf(meId);
        if (peer.isNotEmpty && peer != meId && !ids.contains(peer)) {
          ids.add(peer);
          timeById[peer] = f.matchedAt;
        }
      }
      if (ids.isEmpty) return const [];
      final profiles = await ProfileApi.fetchByIds(ids);
      final byId = {for (final p in profiles) p.id: p};
      return [
        for (final id in ids)
          if (byId[id] != null)
            (profile: byId[id]!, matchedAt: timeById[id]),
      ];
    } catch (e) {
      debugPrint('FriendshipApi.fetchMatchesNewestFirst failed: $e');
      return const [];
    }
  }

  /// Everyone I'm matched with — an `accepted` row in either direction, since
  /// a match is symmetric (who liked first no longer means anything).
  static Future<List<RemoteProfile>> fetchMatches(String meId) async {
    if (!isSupabaseReady || meId.isEmpty) return const [];
    final lists = await Future.wait([
      fetchAcceptedPeers(meId: meId, direction: FriendDirection.followers),
      fetchAcceptedPeers(meId: meId, direction: FriendDirection.following),
    ]);
    final byId = <String, RemoteProfile>{};
    for (final list in lists) {
      for (final p in list) {
        byId[p.id] = p;
      }
    }
    return byId.values.toList(growable: false);
  }

  static Future<void> _notifyNewFollower(String meId, String peerId) async {
    if (!isSupabaseReady) return;
    try {
      final myProfile = await ProfileApi.fetchById(meId);
      final myName = myProfile?.displayName.trim() ?? '';
      final peer = await ProfileApi.fetchById(peerId);
      final lang = peer?.language ?? '';
      await PushDispatcher.notify(
        recipientUid: peerId,
        title: myName.isEmpty
            ? AppStrings.tIn(lang, 'push_friend_request_title')
            : myName,
        body: AppStrings.tIn(lang, 'push_friend_request_body'),
        type: 'friend_request',
        data: {'requesterId': meId},
      );
    } catch (e) {
      debugPrint('friendship notify failed: $e');
    }
  }

  /// "C'est un match" push to [peerId] once both sides have liked each other.
  static Future<void> _notifyMatch(String meId, String peerId) async {
    if (!isSupabaseReady) return;
    try {
      final myProfile = await ProfileApi.fetchById(meId);
      final myName = myProfile?.displayName.trim() ?? '';
      final peer = await ProfileApi.fetchById(peerId);
      final lang = peer?.language ?? '';
      await PushDispatcher.notify(
        recipientUid: peerId,
        title: AppStrings.tIn(lang, 'push_match_title'),
        body: myName.isEmpty
            ? AppStrings.tIn(lang, 'push_match_body_anon')
            : AppStrings.tIn(lang, 'push_match_body', args: {'name': myName}),
        type: 'match',
        data: {'peerId': meId},
      );
    } catch (e) {
      debugPrint('match notify failed: $e');
    }
  }

  /// Accept an incoming like → the two sides are matched. The requester gets
  /// a "c'est un match" push (best effort — never blocks the write).
  static Future<void> accept(String friendshipId) async {
    if (!isSupabaseReady) return;
    final row = await _promoteToMatch(friendshipId);
    if (row == null) return;
    unawaited(_notifyMatch(row.addressee, row.requester));
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

  /// Drop the accepted match between [meId] and [peerId] (hard delete so
  /// either side can like again later — this is not a block).
  /// Returns `true` when at least one accepted row was removed.
  static Future<bool> unmatchWith({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || meId.isEmpty || peerId.isEmpty || meId == peerId) {
      return false;
    }
    final mine = await fetchMine(meId);
    var removed = false;
    for (final f in mine) {
      final involves =
          (f.requester == meId && f.addressee == peerId) ||
          (f.requester == peerId && f.addressee == meId);
      if (!involves || f.status != 'accepted') continue;
      await remove(f.id);
      removed = true;
    }
    return removed;
  }

  /// Viewer-mode helper for the profile screen: where do [meId] and [peerId]
  /// stand?
  ///   * `matched`     → an accepted row either way: both said yes.
  ///   * `iLiked`      → my like is still pending their answer.
  ///   * `peerLikedMe` → their like is waiting for MY answer (one tap = match).
  static Future<({bool matched, bool iLiked, bool peerLikedMe})> matchStateWith({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || meId.isEmpty || peerId.isEmpty || meId == peerId) {
      return (matched: false, iLiked: false, peerLikedMe: false);
    }
    try {
      final mine = await fetchMine(meId);
      var matched = false;
      var iLiked = false;
      var peerLikedMe = false;
      for (final f in mine) {
        final iSentToPeer = f.requester == meId && f.addressee == peerId;
        final peerSentToMe = f.requester == peerId && f.addressee == meId;
        if (!iSentToPeer && !peerSentToMe) continue;
        if (f.status == 'accepted') {
          matched = true;
        } else if (f.status == 'pending') {
          if (iSentToPeer) iLiked = true;
          if (peerSentToMe) peerLikedMe = true;
        }
      }
      return (matched: matched, iLiked: iLiked, peerLikedMe: peerLikedMe);
    } catch (e) {
      debugPrint('FriendshipApi.matchStateWith failed: $e');
      return (matched: false, iLiked: false, peerLikedMe: false);
    }
  }

  /// The pending row where [peerId] liked ME — the one to accept to match back.
  static Future<Friendship?> incomingPendingFrom({
    required String meId,
    required String peerId,
  }) async {
    if (!isSupabaseReady || meId.isEmpty || peerId.isEmpty) return null;
    final row = await _c
        .from('friendships')
        .select()
        .eq('requester', peerId)
        .eq('addressee', meId)
        .eq('status', 'pending')
        .limit(1)
        .maybeSingle();
    if (row == null) return null;
    return Friendship.fromMap(Map<String, dynamic>.from(row));
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
