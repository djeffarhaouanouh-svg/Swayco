import 'package:shared_preferences/shared_preferences.dart';

/// Quand ai-je eu affaire à cette personne pour la dernière fois, message ou
/// NON ?
///
/// La liste Messages se classe sur la date du dernier message. Un appel n'en
/// laisse aucun : on appelle quelqu'un, on raccroche, et sa ligne est toujours
/// enterrée sous des conversations de la semaine dernière. Ce registre comble
/// ce trou — une date par pair, posée au moment de l'appel, que la liste
/// compare à celle du dernier message et garde la plus récente.
///
/// Local à l'appareil, et c'est assumé : il ne sert qu'à ordonner une liste
/// qu'on regarde ici. Rien à synchroniser, rien à migrer.
abstract final class LastInteraction {
  static const _prefix = 'last_interaction.';

  /// Cache mémoire : la liste se retrie à chaque rechargement, on ne va pas
  /// relire le disque à chaque comparaison.
  static Map<String, DateTime>? _cache;

  /// Marque « je viens d'interagir avec [peerId] ».
  static Future<void> touch(String peerId) async {
    if (peerId.isEmpty) return;
    final now = DateTime.now();
    (_cache ??= {})[peerId] = now;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('$_prefix$peerId', now.millisecondsSinceEpoch);
    } catch (_) {
      // Le cache mémoire suffit pour la session en cours.
    }
  }

  /// Tout le registre, prêt à être comparé aux dates de messages.
  static Future<Map<String, DateTime>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String, DateTime>{};
    try {
      final p = await SharedPreferences.getInstance();
      for (final key in p.getKeys()) {
        if (!key.startsWith(_prefix)) continue;
        final ms = p.getInt(key);
        if (ms == null) continue;
        out[key.substring(_prefix.length)] =
            DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {
      // Pas de registre = tri sur les seuls messages, comme avant.
    }
    return _cache = out;
  }
}
