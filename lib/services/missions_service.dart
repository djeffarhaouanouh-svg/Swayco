import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'friendship_api.dart';
import 'like_api.dart';
import 'mission_signal.dart';
import 'profile_api.dart';

/// Stable mission keys, in display order. Mirrored in
/// `profiles.missions_rewarded` and in the UI labels (see `missions_ring.dart`).
const List<String> missionKeys = <String>[
  'friend_request', // sent any friend request
  'post_photo', // added a gallery photo
  'like_someone', // liked a photo / sent a reaction
  'first_message', // sent a real (non-emoji) message
  'add_interests', // picked 3+ interests
  'receive_like', // someone liked one of your photos
];

const int missionCount = 6;

/// One-off bonus (in seconds) granted when ALL missions are done. 15 min.
const int missionTotalRewardSeconds = 15 * 60;

@immutable
class MissionsState {
  const MissionsState({
    this.done = const {},
    this.claimed = false,
    this.loaded = false,
  });

  /// Mission keys the user has completed (sticky — never un-completes).
  final Set<String> done;

  /// True once the 15-minute "all missions done" bonus has been credited.
  final bool claimed;

  /// True once the first fetch has resolved (drives "don't animate the very
  /// first paint" logic and skeleton states).
  final bool loaded;

  int get completed => done.length;
  bool get allDone => done.length >= missionCount;
  bool isDone(String key) => done.contains(key);
}

/// Single source of truth for the onboarding-missions ring shown on the
/// profile (full card) and Discover (compact). Fetches all six flags once,
/// caches them, credits new completions, and emits a [justCompleted] event so
/// the ring can launch its shooting-star animation. Cheap to call on every
/// screen mount — concurrent calls and a short TTL keep it off the hot path
/// (important on Discover).
class MissionsService {
  MissionsService._() {
    // Re-check the moment an action that could complete a mission fires.
    missionSignal.addListener(_bumpFromSignal);
  }
  static final MissionsService instance = MissionsService._();

  /// Current mission state. Widgets bind to this via [ValueListenableBuilder]
  /// so only the ring repaints when it changes — not the whole screen.
  final ValueNotifier<MissionsState> state = ValueNotifier(
    const MissionsState(),
  );

  /// The mission key that just flipped to done AFTER the first load. The ring
  /// consumes it to animate, then calls [consumeJustCompleted].
  final ValueNotifier<String?> justCompleted = ValueNotifier<String?>(null);

  String _userId = '';
  bool _inFlight = false;
  DateTime? _lastFetch;

  /// Re-query the six mission flags (in parallel), credit any newly completed
  /// mission, and update [state]. Returns early if a fetch is already running
  /// or the cache is fresh (< 20 s) for the same user, unless [force] is set —
  /// the profile passes `force: true` so an edit (bio, interests, photo) shows
  /// up immediately and fires the star.
  Future<void> refresh(String userId, {bool force = false}) async {
    if (userId.isEmpty || _inFlight) return;
    if (!force &&
        _userId == userId &&
        _lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < const Duration(seconds: 20)) {
      return;
    }
    _inFlight = true;
    try {
      final res = await Future.wait<dynamic>([
        FriendshipApi.fetchMine(userId),
        LikeApi.fetchMyLikedPhotos(userId),
        ChatApi.fetchMyOutgoingPhotoReactions(userId),
        ChatApi.hasSentAnyMessage(userId),
        ProfileApi.fetchById(userId),
        LikeApi.hasReceivedLike(userId),
      ]);
      final friendships = res[0] as List<Friendship>;
      final liked = res[1] as Set<String>;
      final reactions = res[2] as Map<String, Set<String>>;
      final sentMessage = res[3] as bool;
      final profile = res[4] as RemoteProfile?;
      final receivedLike = res[5] as bool;

      final done = <String>{};
      if (friendships.any((f) => f.requester == userId)) {
        done.add('friend_request');
      }
      if (profile?.photos.isNotEmpty ?? false) done.add('post_photo');
      // "Like" = a heart (LikeApi) OR a Discover rail reaction — both are ways
      // to like someone, from different screens.
      if (liked.isNotEmpty || reactions.isNotEmpty) done.add('like_someone');
      // "First message" must catch a message from ANY screen (chat thread,
      // Discover intro, image, voice), not just Discover-card intros.
      if (sentMessage) done.add('first_message');
      if ((profile?.interests.length ?? 0) >= 3) done.add('add_interests');
      // Passive mission — someone liked one of your photos.
      if (receivedLike) done.add('receive_like');

      final wasLoaded = state.value.loaded;
      final prevDone = state.value.done;

      // Merge into the STICKY set + grant the 15-min bonus once all are done.
      final r = await ProfileApi.syncMissions(
        userId: userId,
        liveDone: done,
        validKeys: missionKeys.toSet(),
        totalCount: missionCount,
        totalRewardSeconds: missionTotalRewardSeconds,
      );

      _userId = userId;
      _lastFetch = DateTime.now();
      state.value = MissionsState(
        done: r.done,
        claimed: r.claimed,
        loaded: true,
      );

      // Fire the shooting star only for a mission that flipped AFTER the first
      // load — otherwise the ring would "complete" everything on first paint.
      if (wasLoaded) {
        final newly = r.done.difference(prevDone);
        if (newly.isNotEmpty) justCompleted.value = newly.first;
      }
    } catch (e) {
      debugPrint('MissionsService.refresh failed: $e');
    } finally {
      _inFlight = false;
    }
  }

  void _bumpFromSignal() => bump();

  /// Re-check missions for the current user after an action that might complete
  /// one (a like, message, reaction, friend request). No-op until the first
  /// refresh has established the user id. Concurrency-guarded by [refresh].
  Future<void> bump() async {
    if (_userId.isEmpty) return;
    await refresh(_userId, force: true);
  }

  void consumeJustCompleted() => justCompleted.value = null;
}
