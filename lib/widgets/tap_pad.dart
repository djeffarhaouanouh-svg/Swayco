import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Zone de tap minimale (en pixels logiques) des petits boutons.
const double kMinTapTarget = 44;

/// Agrandit la zone de tap d'un petit bouton jusqu'à [minSize] SANS toucher à la
/// mise en page : le widget garde exactement la taille de son enfant (rien ne
/// bouge, rien ne se décale), seul le test de toucher accepte les points autour.
/// Un enfant déjà assez grand n'est pas modifié. C'est la même idée que le
/// « MaterialTapTargetSize » des boutons Material, mais sans la place en plus.
///
/// Limite : la zone ne dépasse pas le parent (un Row, un Stack…) qui, lui,
/// refuse les touchers hors de ses bords ; et un voisin peint par-dessus garde
/// la priorité sur la marge.
class TapPad extends SingleChildRenderObjectWidget {
  const TapPad({super.key, this.minSize = kMinTapTarget, super.child});

  final double minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTapPad(minSize);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderTapPad).minSize = minSize;
  }
}

class _RenderTapPad extends RenderProxyBox {
  _RenderTapPad(this._minSize);

  double _minSize;
  set minSize(double v) {
    if (v != _minSize) _minSize = v;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    final c = child;
    if (c == null) return false;
    final dx = math.max(0.0, (_minSize - size.width) / 2);
    final dy = math.max(0.0, (_minSize - size.height) / 2);
    if (dx == 0 && dy == 0) return false;
    final padded = Rect.fromLTRB(-dx, -dy, size.width + dx, size.height + dy);
    if (!padded.contains(position)) return false;
    // On présente le toucher au centre de l'enfant, comme le fait Flutter pour
    // la marge de ses propres boutons.
    final center = size.center(Offset.zero);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(center),
      position: center,
      hitTest: (BoxHitTestResult result, Offset position) =>
          c.hitTest(result, position: center),
    );
  }
}

/// [GestureDetector] à zone de tap élargie (voir [TapPad]).
class PadTap extends StatelessWidget {
  const PadTap({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.behavior,
    this.minSize = kMinTapTarget,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior? behavior;
  final double minSize;

  @override
  Widget build(BuildContext context) => TapPad(
        // Inerte (onTap nul) : pas de marge, on n'avale aucun toucher.
        minSize: onTap == null && onLongPress == null ? 0 : minSize,
        child: GestureDetector(
          behavior: behavior,
          onTap: onTap,
          onLongPress: onLongPress,
          child: child,
        ),
      );
}

/// [InkWell] à zone de tap élargie (voir [TapPad]).
class PadInkWell extends StatelessWidget {
  const PadInkWell({
    super.key,
    required this.child,
    this.onTap,
    this.customBorder,
    this.borderRadius,
    this.minSize = kMinTapTarget,
  });

  final Widget child;
  final VoidCallback? onTap;
  final ShapeBorder? customBorder;
  final BorderRadius? borderRadius;
  final double minSize;

  @override
  Widget build(BuildContext context) => TapPad(
        minSize: onTap == null ? 0 : minSize,
        child: InkWell(
          onTap: onTap,
          customBorder: customBorder,
          borderRadius: borderRadius,
          child: child,
        ),
      );
}
