import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'revenue_cat.dart';

/// Tout le monde peut écrire à tout le monde (le match n'existe plus). Seule
/// limite : un compte gratuit contacte [freeLimit] NOUVELLES personnes par jour
/// (date locale), le Pro est illimité. Local à l'appareil, comme les profils du
/// jour. Répondre, ou continuer une conversation, ne compte jamais.
abstract final class NewContacts {
  static const int freeLimit = 5;

  static String _key(String meId) => 'new_contacts_$meId';

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  /// Les personnes contactées pour la première fois aujourd'hui.
  static Future<List<String>> _contacted(String meId) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_key(meId)) ?? const <String>[];
    if (raw.isEmpty || raw.first != _today()) return const [];
    return raw.sublist(1);
  }

  /// Puis-je écrire à [peerId] ? Si oui et que c'est quelqu'un de nouveau, la
  /// personne est comptée tout de suite (réessayer après un échec est gratuit).
  static Future<bool> take({
    required String meId,
    required String peerId,
  }) async {
    if (meId.isEmpty || peerId.isEmpty) return true;
    if (RevenueCat.proActive.value) return true;
    try {
      final done = await _contacted(meId);
      if (done.contains(peerId)) return true;
      final ids = [meId, peerId]..sort();
      // Lecture ratée (hors ligne) : on ne compte rien, l'envoi dira le reste.
      final known = await ChatApi.hasMessage('dm-${ids[0]}-${ids[1]}');
      if (known != false) return true;
      if (done.length >= freeLimit) return false;
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_key(meId), [_today(), ...done, peerId]);
      return true;
    } catch (_) {
      return true;
    }
  }
}
