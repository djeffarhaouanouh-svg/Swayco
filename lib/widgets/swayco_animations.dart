// swayco_animations.dart — à poser dans lib/widgets/
//
// Sept animations pour Swayco. Aucune dépendance au-delà de Flutter, aucune
// API plus récente que Flutter 3.41.2.
//
//   PopBadge          pastille rouge de la barre du bas qui rebondit
//   BlurRevealAvatar  le flou d'un liker se dissipe quand il est révélé
//   MessageEntrance   bulle de message (envoyée ou reçue) qui arrive
//   EntranceTracker   décide quelles bulles sont nouvelles (pas au 1er affichage)
//   SwapIcon          GIF ⇄ flèche d'envoi avec pivot
//   popInFrameBuilder photo qui apparaît en fondu + zoom une fois chargée
//
// La liste « Qui m'a liké » utilise le FadeSlideIn qui existe déjà
// (lib/widgets/appear.dart) : voir INTEGRATION.md.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 2 · Pastille rouge de la barre du bas
// ─────────────────────────────────────────────────────────────────────────────

/// Enveloppe la pastille (point ou « +N »). Elle grandit à son apparition, puis
/// rebondit chaque fois que [count] augmente.
class PopBadge extends StatefulWidget {
  const PopBadge({super.key, required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  State<PopBadge> createState() => _PopBadgeState();
}

class _PopBadgeState extends State<PopBadge> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  )..forward();
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  late final Animation<double> _inScale =
      CurvedAnimation(parent: _in, curve: Curves.easeOutBack);
  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.6)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.6, end: 0.9)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.9, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 30,
    ),
  ]).animate(_pop);

  @override
  void didUpdateWidget(PopBadge old) {
    super.didUpdateWidget(old);
    if (widget.count > old.count) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _in.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_in, _pop]),
      builder: (_, child) => Transform.scale(
        scale: _inScale.value * _popScale.value,
        child: child,
      ),
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4 · Liker révélé : le flou se dissipe
// ─────────────────────────────────────────────────────────────────────────────

/// Affiche [child] (l'avatar) flouté tant que [revealed] est faux. Au passage
/// à vrai, le flou se dissipe en 600 ms avec un petit gonflement.
class BlurRevealAvatar extends StatefulWidget {
  const BlurRevealAvatar({
    super.key,
    required this.revealed,
    required this.child,
    this.sigma = 4,
  });

  final bool revealed;
  final Widget child;

  /// Flou de départ (celui de BlurredAvatar : 4).
  final double sigma;

  @override
  State<BlurRevealAvatar> createState() => _BlurRevealAvatarState();
}

class _BlurRevealAvatarState extends State<BlurRevealAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    value: widget.revealed ? 1 : 0,
  );

  @override
  void didUpdateWidget(BlurRevealAvatar old) {
    super.didUpdateWidget(old);
    if (widget.revealed && !old.revealed) _c.forward(from: 0);
    if (!widget.revealed && old.revealed) _c.value = 0;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = Curves.easeOut.transform(_c.value);
        final sigma = widget.sigma * (1 - t);
        // Petit gonflement au milieu de la révélation.
        final pop = 1 + 0.12 * (1 - (2 * _c.value - 1).abs()) *
            (_c.value > 0 && _c.value < 1 ? 1 : 0);
        Widget out = child!;
        if (sigma > 0.05) {
          out = ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: out,
          );
        }
        return Transform.scale(scale: pop, child: ClipOval(child: out));
      },
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// A + B · Bulles de message qui arrivent
// ─────────────────────────────────────────────────────────────────────────────

/// Retient quels messages ont déjà été vus, pour n'animer que les NOUVEAUX.
/// À créer une fois dans l'état de l'écran de conversation.
///
/// Sans lui, chaque bulle rejouerait son animation à l'ouverture de la
/// conversation et chaque fois qu'on remonte dans l'historique.
class EntranceTracker {
  final Set<String> _seen = {};
  bool _primed = false;

  bool get primed => _primed;

  /// Premier chargement : tout ce qui est déjà là est considéré comme vu.
  void prime(Iterable<String> ids) {
    if (_primed) return;
    _seen.addAll(ids);
    _primed = true;
  }

  /// Vrai UNE seule fois par message, et seulement après [prime].
  bool take(String id) => _primed && _seen.add(id);
}

/// La bulle monte en grossissant avec un léger rebond, et les bulles du
/// dessus s'écartent en douceur (la hauteur grandit au lieu de sauter).
/// [mine] : arrive de la droite ; sinon de la gauche.
class MessageEntrance extends StatefulWidget {
  const MessageEntrance({
    super.key,
    required this.child,
    required this.mine,
    required this.animate,
  });

  final Widget child;
  final bool mine;
  final bool animate;

  @override
  State<MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _size =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<double> _spring =
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: const Interval(0, 0.5));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c.isCompleted) return widget.child;
    final dx = widget.mine ? 18.0 : -18.0;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final s = _spring.value;
        return SizeTransition(
          sizeFactor: _size,
          axisAlignment: -1,
          child: Opacity(
            opacity: _fade.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(dx * (1 - s), 14 * (1 - s)),
              child: Transform.scale(
                scale: 0.8 + 0.2 * s,
                alignment:
                    widget.mine ? Alignment.bottomRight : Alignment.bottomLeft,
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// C · Bouton rond : GIF ⇄ flèche d'envoi
// ─────────────────────────────────────────────────────────────────────────────

/// Remplace `Icon(...)` dans le rond du champ de message. Quand [icon]
/// change, l'ancienne icône rétrécit en pivotant et la nouvelle arrive avec
/// un petit dépassement.
class SwapIcon extends StatelessWidget {
  const SwapIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 22,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: anim,
        child: RotationTransition(
          turns: Tween<double>(begin: 0.15, end: 0).animate(anim),
          child: child,
        ),
      ),
      child: Icon(icon, key: ValueKey(icon), color: color, size: size),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// D · Photo qui apparaît
// ─────────────────────────────────────────────────────────────────────────────

/// À passer à `Image.network(frameBuilder: popInFrameBuilder)`.
/// Si l'image est déjà en cache elle s'affiche tout de suite ; sinon elle
/// arrive en fondu avec un zoom et un flou qui se dissipe.
Widget popInFrameBuilder(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) return child;
  return TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: frame == null ? 0 : 1),
    duration: const Duration(milliseconds: 520),
    curve: Curves.easeOutBack,
    builder: (_, t, c) {
      final o = t.clamp(0.0, 1.0);
      final sigma = 8 * (1 - o);
      Widget out = Transform.scale(scale: 0.85 + 0.15 * t, child: c);
      if (sigma > 0.1) {
        out = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: out,
        );
      }
      return Opacity(opacity: o, child: out);
    },
    child: child,
  );
}
