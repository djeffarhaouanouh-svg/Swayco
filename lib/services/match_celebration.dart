import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bus that surfaces a brand-new match to the OTHER peer (the one who
/// didn't just tap Matcher / Accepter). [RootShell] listens and pushes
/// the celebration overlay. Local celebrators also register here so the
/// same match never pops twice.
abstract final class MatchCelebration {
  static const String _kShownKey = 'match_celebrated_ids';

  /// Le compte dont la mémoire est chargée. La mémoire est PAR COMPTE : avec une
  /// seule liste pour tout le téléphone, se connecter à un autre compte faisait
  /// « oublier » les matchs du premier ([forgetEnded]), qui étaient alors refêtés
  /// au retour.
  static String _account = '';

  static String get _key => '${_kShownKey}_$_account';

  /// Signal : une célébration attend (l'id du dernier match offert), ou null une
  /// fois la file vidée. Les célébrations elles-mêmes sont dans [_queue] : avec
  /// une seule place, un 2e match arrivé pendant l'animation du 1er l'écrasait
  /// et n'était jamais montré.
  static final ValueNotifier<String?> pendingPeerId =
      ValueNotifier<String?>(null);

  /// Matchs à célébrer, dans l'ordre d'arrivée.
  static final List<String> _queue = <String>[];

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
  static Future<bool> restore(String accountId) async {
    if (_account != accountId) {
      // Changement de compte : on repart de SA mémoire, sans celle du précédent.
      if (_account.isNotEmpty) {
        _alreadyShown.clear();
        _queue.clear();
        pendingPeerId.value = null;
      }
      _account = accountId;
    }
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getStringList(_key);
      if (saved == null) return false;
      _alreadyShown.addAll(saved);
      return true;
    } catch (e) {
      debugPrint('match: restore failed: $e');
      return false;
    }
  }

  static Future<void> _persist() async {
    // Aucun compte chargé : gardé en mémoire, écrit au prochain passage.
    if (_account.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_key, _alreadyShown.toList());
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
    _queue.add(id);
    pendingPeerId.value = id;
  }

  /// Le prochain match à célébrer (le plus ancien), ou null quand il n'y en a plus.
  static String? takeNext() {
    if (_queue.isEmpty) {
      pendingPeerId.value = null;
      return null;
    }
    final id = _queue.removeAt(0);
    if (_queue.isEmpty) pendingPeerId.value = null;
    return id;
  }

  /// Oublie les personnes dont le match n'existe plus : [currentMatchIds] est la
  /// liste de mes matchs d'AUJOURD'HUI. Sans ça, quelqu'un fêté une fois l'était
  /// pour toujours — rompre puis se rematcher (deux comptes de test, une erreur
  /// corrigée) ne rejouait aucune animation, ni d'un côté ni de l'autre.
  ///
  /// Une liste VIDE ne purge rien : une lecture qui échoue ou une compte sans
  /// match ne doit pas effacer la mémoire, sinon tous les matchs seraient
  /// refêtés au prochain lancement.
  static void forgetEnded(Set<String> currentMatchIds) {
    if (currentMatchIds.isEmpty) return;
    final gone = _alreadyShown.difference(currentMatchIds);
    if (gone.isEmpty) return;
    _alreadyShown.removeAll(gone);
    _persist();
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
