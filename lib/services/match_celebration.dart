import 'package:flutter/foundation.dart';

/// Bus that surfaces a brand-new match to the OTHER peer (the one who
/// didn't just tap Matcher / Accepter). [RootShell] listens and pushes
/// the celebration overlay. Local celebrators also register here so the
/// same match never pops twice.
abstract final class MatchCelebration {
  /// Peer id awaiting an in-app celebration, or null.
  static final ValueNotifier<String?> pendingPeerId =
      ValueNotifier<String?>(null);

  static final Set<String> _alreadyShown = <String>{};

  /// Ask the shell to celebrate a match with [peerId]. No-ops when this
  /// device already showed that celebration (local tap or prior offer).
  static void offer(String peerId) {
    final id = peerId.trim();
    if (id.isEmpty) return;
    if (!_alreadyShown.add(id)) {
      debugPrint('match: skip duplicate celebration for $id');
      return;
    }
    pendingPeerId.value = id;
  }

  /// Mark [peerId] as already celebrated without enqueueing — used by the
  /// local accept/like-back path that shows the overlay itself.
  static void markShown(String peerId) {
    final id = peerId.trim();
    if (id.isEmpty) return;
    _alreadyShown.add(id);
  }

  static void consume() => pendingPeerId.value = null;
}
