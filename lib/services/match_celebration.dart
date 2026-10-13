import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bus that surfaces a brand-new match to the OTHER peer (the one who
/// didn't just tap Matcher / Accepter). [RootShell] listens and pushes
/// the celebration overlay. Local celebrators also register here so the
/// same match never pops twice.
abstract final class MatchCelebration {
  static const String _kShownKey = 'match_celebrated_ids';

  /// Peer id awaiting an in-app celebration, or null.
  static final ValueNotifier<String?> pendingPeerId =
      ValueNotifier<String?>(null);

  /// Bumped each time the shell sees a brand-new match, so other screens (the
  /// Discover deck) can re-read my friendships once instead of polling.
  static final ValueNotifier<int> matchesChanged = ValueNotifier<int>(0);

  static final Set<String> _alreadyShown = <String>{};

  /// Peers whose match was already celebrated (this session or an earlier one).
  static Set<String> get shown => _alreadyShown;

  /// Merges the celebrations remembered from earlier sessions. Returns false
  /// when nothing was ever stored (first launch with this feature): the caller
  /// then treats the matches it finds as the baseline instead of replaying them.
  /// Without this, a match made while the app was CLOSED (an AI accepting
  /// your like, say) was swallowed as "already there" at the next launch.
  static Future<bool> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getStringList(_kShownKey);
      if (saved == null) return false;
      _alreadyShown.addAll(saved);
      return true;
    } catch (e) {
      debugPrint('match: restore failed: $e');
      return false;
    }
  }

  static Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kShownKey, _alreadyShown.toList());
    } catch (e) {
      debugPrint('match: persist failed: $e');
    }
  }

  /// Baseline: [ids] count as already celebrated. Always writes, even for an
  /// empty set, so the next launch knows a baseline exists.
  static Future<void> seed(Iterable<String> ids) {
    _alreadyShown.addAll(ids);
    return _persist();
  }

  /// Ask the shell to celebrate a match with [peerId]. No-ops when this
  /// device already showed that celebration (local tap or prior offer).
  static void offer(String peerId) {
    final id = peerId.trim();
    if (id.isEmpty) return;
    if (!_alreadyShown.add(id)) {
      debugPrint('match: skip duplicate celebration for $id');
      return;
    }
    _persist();
    pendingPeerId.value = id;
  }

  /// Mark [peerId] as already celebrated without enqueueing — used by the
  /// local accept/like-back path that shows the overlay itself.
  static void markShown(String peerId) {
    final id = peerId.trim();
    if (id.isEmpty) return;
    if (_alreadyShown.add(id)) _persist();
  }

  static void consume() => pendingPeerId.value = null;
}
