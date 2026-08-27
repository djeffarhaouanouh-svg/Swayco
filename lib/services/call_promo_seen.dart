import 'package:shared_preferences/shared_preferences.dart';

/// Which conversations already showed the "call — Swayco traduit" promo
/// card. One-shot per conversation: the first time it's opened, never
/// again after that, even across app restarts.
abstract final class CallPromoSeen {
  static const _key = 'call_promo_seen_conversation_ids';

  static Future<bool> hasSeen(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList(_key) ?? const <String>[];
    return seen.contains(conversationId);
  }

  static Future<void> markSeen(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_key) ?? const <String>[]).toSet()
      ..add(conversationId);
    await prefs.setStringList(_key, seen.toList());
  }
}
