import 'package:shared_preferences/shared_preferences.dart';

/// Rewarded video ad — the "watch a video to reveal a like" unlock.
///
/// Not wired yet: AdMob isn't configured, so [isAvailable] is false and the
/// Likes page shows "coming soon". Plug google_mobile_ads into [show]: return
/// true only once the user earned the reward.
abstract final class RewardedVideo {
  static bool get isAvailable => false;

  static Future<bool> show() async => false;
}

/// Likers revealed by a rewarded video, one per video, remembered per account
/// on this device.
abstract final class LikesUnlocks {
  static String _key(String myId) => 'likes_unlocked_$myId';

  static Future<Set<String>> load(String myId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key(myId)) ?? const <String>[]).toSet();
  }

  static Future<void> add(String myId, String likerId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_key(myId)) ?? const <String>[]).toSet()
      ..add(likerId);
    await prefs.setStringList(_key(myId), ids.toList());
  }
}
