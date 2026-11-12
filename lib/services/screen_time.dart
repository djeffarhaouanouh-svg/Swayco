import 'analytics.dart';

/// Combien de temps on reste sur chaque écran, pour comprendre ce que les gens
/// font vraiment dans l'app (et pas seulement quels écrans ils ouvrent).
///
/// Un événement `screen_time` part à chaque FIN de passage sur un écran, avec
/// uniquement le nom de l'écran et la durée en secondes : jamais de contenu, de
/// nom ni de personne. Le temps passé app en arrière-plan n'est pas compté.
///
/// Les écrans sont un empilement : l'onglet (`chat`, `discover`, `requests`,
/// `profile`), puis ce qui est ouvert par-dessus (`thread` pour une
/// conversation). Quand on ferme le dessus, l'onglet reprend son compte.
abstract final class ScreenTime {
  static final List<String> _stack = [];
  static DateTime? _since;

  /// Durées trop courtes pour dire quoi que ce soit (un onglet traversé).
  static const int _minSeconds = 1;

  /// Une séance oubliée ouverte ne doit pas fausser les moyennes.
  static const int _maxSeconds = 30 * 60;

  static String? get current => _stack.isEmpty ? null : _stack.last;

  /// Écrit la durée de l'écran courant (s'il y en a un, et si l'app est au
  /// premier plan), et repart de zéro.
  static void _emit() {
    final screen = current;
    final since = _since;
    if (screen == null || since == null) return;
    final s = DateTime.now().difference(since).inSeconds;
    if (s < _minSeconds) return;
    try {
      Analytics.track('screen_time', props: {
        'screen': screen,
        'seconds': s > _maxSeconds ? _maxSeconds : s,
      });
    } catch (_) {}
  }

  /// On change d'onglet : tout ce qui était empilé se ferme.
  static void setTab(String tab) {
    _emit();
    _stack
      ..clear()
      ..add(tab);
    _since = DateTime.now();
  }

  /// Un écran s'ouvre par-dessus l'onglet (une conversation, par exemple).
  static void push(String screen) {
    _emit();
    _stack.add(screen);
    _since = DateTime.now();
  }

  /// Cet écran se ferme : l'onglet (ou l'écran dessous) reprend.
  static void pop(String screen) {
    if (_stack.length < 2 || _stack.last != screen) return;
    _emit();
    _stack.removeLast();
    _since = DateTime.now();
  }

  /// L'app passe en arrière-plan : on arrête de compter.
  static void pause() {
    _emit();
    _since = null;
  }

  /// L'app revient au premier plan : on reprend là où on était.
  static void resume() {
    if (_stack.isNotEmpty && _since == null) _since = DateTime.now();
  }
}
