import 'package:flutter/widgets.dart';

/// L'aimantation du fil Discover : toutes les cartes font la même hauteur, un
/// geste mène à la carte suivante et l'arrête au milieu de l'écran. La première
/// reste en haut ; sous la dernière (fin du fil), le défilement est libre.
class FeedSnap {
  /// Nombre de cartes (publicités comprises).
  int count = 0;

  /// Hauteur d'une carte, espace compris.
  double extent = 1;
  double cardHeight = 0;

  /// Marge au-dessus de la première carte.
  double topPad = 0;

  /// Ce que la barre du bas recouvre quand elle revient.
  double bottomInset = 0;

  /// Pendant qu'on écrit, la liste est cachée et change de hauteur (clavier) :
  /// on ne l'aimante plus.
  bool frozen = false;

  /// Revenir sur la carte [i] au prochain recalage.
  void hold(int i) {
    _from = i;
    _target = i;
  }

  /// La carte d'où le geste est parti, puis celle qu'on a décidé d'atteindre.
  int _from = 0;
  int? _target;

  /// Le sens du dernier geste : 1 vers le bas, -1 vers le haut, 0 sur place.
  int direction = 0;

  /// Vitesse (px/s) à partir de laquelle un geste compte comme un élan.
  static const double _fling = 60;

  /// Sans élan : la part de carte qu'il faut avoir tirée pour changer.
  static const double _pull = 0.1;

  /// La position de défilement qui montre la carte [i] au milieu : centrée,
  /// sans que son bas passe sous la barre.
  double offsetOf(int i, ScrollMetrics m) {
    final view = m.viewportDimension;
    var top = (view - cardHeight) / 2;
    final above = view - bottomInset - cardHeight - 4;
    if (above < top) top = above;
    if (top < topPad) top = topPad;
    return (topPad + i * extent - top)
        .clamp(m.minScrollExtent, m.maxScrollExtent);
  }

  /// La carte la plus proche ; [count] quand on est dans la fin du fil.
  int nearest(ScrollMetrics m) {
    if (count == 0) return 0;
    if (m.pixels > offsetOf(count - 1, m) + extent * 0.3) return count;
    var best = 0;
    var gap = double.infinity;
    for (var i = 0; i < count; i++) {
      final d = (offsetOf(i, m) - m.pixels).abs();
      if (d < gap) {
        gap = d;
        best = i;
      }
    }
    return best;
  }

  /// Un doigt se pose : un nouveau geste. Deux gestes rapides avancent de deux
  /// cartes (on repart de celle qu'on visait).
  void dragStarted(ScrollMetrics m) {
    _from = _target ?? nearest(m);
    _target = null;
  }

  /// Un cran de molette : la carte d'avant ou d'après.
  void step(ScrollPosition position, int direction) {
    if (count == 0 || position is! ScrollPositionWithSingleContext) return;
    final from = _target ?? nearest(position);
    final next = from + direction;
    if (next < 0) return;
    this.direction = direction;
    if (next >= count) {
      // La fin du fil.
      _target = null;
      _from = count;
      position.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    _from = from;
    _target = next;
    position.goBallistic(direction * 700);
  }

  /// La carte à rejoindre quand le geste est lâché, ou `null` pour laisser le
  /// défilement libre. Gardée jusqu'au prochain geste : la hauteur de la liste
  /// change pendant l'animation (les pays se rangent), la cible non.
  int? resolve(ScrollMetrics m, double velocity) {
    if (count == 0) return null;
    final kept = _target;
    if (kept != null) {
      // À l'arrêt et loin de la cible : la liste a été déplacée par ailleurs
      // (« revenir en haut »), l'ancienne cible ne compte plus.
      final stale = velocity == 0 &&
          (kept >= count ||
              (offsetOf(kept, m) - m.pixels).abs() > extent * 0.5);
      if (!stale) return kept < count ? kept : null;
      _target = null;
      _from = nearest(m);
    }
    final last = offsetOf(count - 1, m);
    final from = _from.clamp(0, count);
    var way = 0;
    if (velocity > _fling) {
      way = 1;
    } else if (velocity < -_fling) {
      way = -1;
    } else if (from < count) {
      final moved = m.pixels - offsetOf(from, m);
      if (moved > extent * _pull) way = 1;
      if (moved < -extent * _pull) way = -1;
    }
    direction = way;
    // Dans la fin du fil : libre, sauf en remontant au-dessus de la dernière.
    if (m.pixels > last + 1 && from >= count - 1 && way >= 0) return null;
    var next = from + way;
    // Un long glissé a pu dépasser la voisine : on s'arrête là où il est.
    final here = nearest(m);
    if (way > 0 && here > next) next = here;
    if (way < 0 && here < next) next = here;
    if (next >= count) return null;
    if (next < 0) next = 0;
    return _target = next;
  }
}

/// La physique qui applique [FeedSnap].
class FeedSnapPhysics extends ScrollPhysics {
  const FeedSnapPhysics(this.snap, {super.parent});

  final FeedSnap snap;

  @override
  FeedSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      FeedSnapPhysics(snap, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (snap.frozen) return null;
    // Hors des bords (rebond, tirer pour recharger) : comme d'habitude.
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final target = snap.resolve(position, velocity);
    if (target == null) {
      return super.createBallisticSimulation(position, velocity);
    }
    final offset = snap.offsetOf(target, position);
    final tolerance = toleranceFor(position);
    if ((offset - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      offset,
      velocity,
      tolerance: tolerance,
    );
  }

  /// Pas d'élan reporté d'un geste à l'autre : un geste, une carte.
  @override
  double carriedMomentum(double existingVelocity) => 0;

  @override
  bool get allowImplicitScrolling => false;
}
