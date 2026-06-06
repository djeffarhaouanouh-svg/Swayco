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
  'like_someone', // liked at least one photo
  'first_message', // sent a real (non-emoji) message
  'fill_bio', // bio is non-empty
  'add_interests', // picked 3+ interests
];

const int missionCount = 6;

/// Call-time granted per completed mission (in seconds). 6 × 5 min = 30 min.
const int missionRewardSeconds = 5 * 60;

@immutable
class MissionsState {
  const MissionsState({
    this.done = const {},
    this.rewarded = const {},
    this.loaded = false,
  });

  /// Mission keys the user has completed.
  final Set<String> done;

  /// Mission keys whose minutes reward has been credited.
  final Set<String> rewarded;

  /// True once the first fetch has resolved (drives "don't animate the very
  /// first paint" logic and skeleton states).
  final bool loaded;

  int get completed => done.length;
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
      ]);
      final friendships = res[0] as List<Friendship>;
      final liked = res[1] as Set<String>;
      final reactions = res[2] as Map<String, Set<String>>;
      final sentMessage = res[3] as bool;
      final profile = res[4] as RemoteProfile?;

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
      if (profile?.bio.trim().isNotEmpty ?? false) done.add('fill_bio');
      if ((profile?.interests.length ?? 0) >= 3) done.add('add_interests');

      final wasLoaded = state.value.loaded;
      final prevDone = state.value.done;

      // Credit minutes for newly-done, not-yet-rewarded missions (idempotent).
      final r = await ProfileApi.syncMissionRewards(
        userId: userId,
        doneKeys: done,
        rewardSecondsEach: missionRewardSeconds,
      );

      _userId = userId;
      _lastFetch = DateTime.now();
      state.value = MissionsState(done: done, rewarded: r.rewarded, loaded: true);

      // Fire the shooting star only for a mission that flipped AFTER the first
      // load — otherwise the ring would "complete" everything on first paint.
      if (wasLoaded) {
        final newly = done.difference(prevDone);
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
