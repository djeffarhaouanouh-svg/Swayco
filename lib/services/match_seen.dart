import 'package:shared_preferences/shared_preferences.dart';

/// Which matches the user has already LAID EYES ON, so the count next to
/// "Nouveaux matchs" clears once the rail has actually been looked at.
///
/// The bubble itself stays until a message is sent (that's what moves it into
/// the conversation list) — only the badge is silenced. Local to the device,
/// like the chat "seen" pointers: a match seen on the phone doesn't need to be
/// re-announced there, and the web build re-announcing it once is harmless.
abstract final class MatchSeen {
  static const _key = 'seen_match_ids';

  /// The ids of every match already shown in the rail.
  static Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  /// Mark [ids] as seen. Returns the full seen set. Prunes ids that are no
  /// longer matches ([stillMatched]) so the list can't grow forever.
  static Future<Set<String>> markSeen(
    Iterable<String> ids, {
    required Set<String> stillMatched,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_key) ?? const <String>[]).toSet()
      ..addAll(ids)
      ..removeWhere((id) => !stillMatched.contains(id));
    await prefs.setStringList(_key, seen.toList());
    return seen;
  }
}
