import 'dart:async';

import 'package:flutter/material.dart';

/// Déclenche [onVisible] UNE fois, quand l'élément passe réellement sous les
/// yeux — pas quand la page s'ouvre, pas quand il est construit hors de l'écran.
///
/// Les animations du guide (la traduction qui se joue, la vidéo du globe) ne
/// doivent démarrer que lorsque la personne arrive dessus en faisant défiler :
/// sinon elles se jouent dans le vide, plus bas que l'écran, et il n'y a plus
/// rien à voir quand on y arrive.
///
/// Sans dépendance : on regarde, quelques fois par seconde, où se trouve le
/// cadre de l'élément par rapport à l'écran. « Visible » = au moins 40 % de sa
/// hauteur dans la zone de lecture (hors en-tête et hors zone d'écriture).
class OnVisible extends StatefulWidget {
  const OnVisible({super.key, required this.onVisible, required this.child});

  final VoidCallback onVisible;
  final Widget child;

  @override
  State<OnVisible> createState() => _OnVisibleState();
}

class _OnVisibleState extends State<OnVisible> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 160), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final top = box.localToGlobal(Offset.zero).dy;
    final height = box.size.height;
    if (height <= 0) return;
    // La zone de lecture : sous l'en-tête (~90 px) et au-dessus de la barre
    // d'écriture (~110 px).
    final readTop = pad.top + 90;
    final readBottom = size.height - 110 - pad.bottom;
    final visibleTop = top < readTop ? readTop : top;
    final bottom = top + height;
    final visibleBottom = bottom > readBottom ? readBottom : bottom;
    final shown = visibleBottom - visibleTop;
    if (shown >= height * 0.4 || shown >= (readBottom - readTop) * 0.8) {
      _timer?.cancel();
      _timer = null;
      widget.onVisible();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
