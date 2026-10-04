import 'package:shared_preferences/shared_preferences.dart';

/// Demandes de message spécial déjà traitées (acceptées OU refusées), par
/// compte : une fois traitée, la demande ne revient plus dans le fil ni dans
/// la section « Message spécial » de la liste.
abstract final class SpecialRequest {
  static String _key(String myId) => 'special_handled_$myId';

  static Future<Set<String>> handled(String myId) async {
    if (myId.isEmpty) return <String>{};
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(_key(myId)) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> markHandled(String myId, String peerId) async {
    if (myId.isEmpty || peerId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final s = (p.getStringList(_key(myId)) ?? const <String>[]).toSet()
        ..add(peerId);
      await p.setStringList(_key(myId), s.toList());
    } catch (_) {}
  }
}
