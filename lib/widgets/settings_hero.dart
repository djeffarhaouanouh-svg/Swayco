import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';

/// Place du rond « retour » des Réglages, comptée depuis le bord gauche : celle
/// du bouton retour de l'AppBar (14 de marge).
const double _kBackLeft = 14;

/// Durées partagées par l'aller et le retour.
const Duration _kSlide = Duration(milliseconds: 520);
const Duration _kPause = Duration(milliseconds: 120);
const Duration _kFade = Duration(milliseconds: 260);

/// Où était l'engrenage la dernière fois qu'il a ouvert les Réglages (coin
/// haut-gauche, coordonnées écran) : le retour y glisse avant de refermer.
Offset? _lastGear;

/// Les Réglages apparaissent en fondu : le rond est DÉJÀ arrivé à la place de
/// leur bouton retour, la page n'a rien d'autre à animer.
Route<T> settingsHeroRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: _kFade,
    reverseTransitionDuration: _kFade,
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (_, anim, _, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

/// Fait voyager UN SEUL rond dans l'overlay, au-dessus des deux pages, de
/// [from] à [to] (coordonnées écran) : pendant le glissement, la pause ET le
/// fondu de la page, c'est toujours le même rond qu'on voit — plus de
/// doublon qui apparaît en fondu ni de saut d'une page à l'autre.
class _FlyingDisc {
  _FlyingDisc({
    required this.overlay,
    required this.from,
    required this.to,
    required this.reverse,
  }) {
    entry = OverlayEntry(
      builder: (_) => ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, _) {
          final t = Curves.easeInOutCubic.transform(v);
          final pos = Offset.lerp(from, to, t)!;
          return Positioned(
            left: pos.dx,
            top: pos.dy,
            child: IgnorePointer(
              // Aller : engrenage → flèche ; retour : flèche → engrenage.
              child: SettingsDisc(t: reverse ? 1 - t : t),
            ),
          );
        },
      ),
    );
    overlay.insert(entry);
  }

  final OverlayState overlay;
  final Offset from;
  final Offset to;
  final bool reverse;
  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  late final OverlayEntry entry;

  /// Repasse au-dessus d'une page qui vient d'être poussée.
  void bringToFront() {
    if (_done || !entry.mounted) return;
    entry.remove();
    overlay.insert(entry);
  }

  bool _done = false;

  void dispose() {
    if (_done) return;
    _done = true;
    if (entry.mounted) entry.remove();
    entry.dispose();
    progress.dispose();
  }
}

/// Le rond « engrenage » du profil. Au tap : il glisse jusqu'à la place du
/// bouton retour en roulant sur lui-même (l'engrenage devient flèche), s'y
/// POSE, puis la page des Réglages s'ouvre en fondu SOUS lui. Il ne disparaît
/// qu'une fois la page entièrement là, pile sur le bouton retour identique.
class SettingsHeroButton extends StatefulWidget {
  const SettingsHeroButton({super.key, required this.onOpen});

  /// Ouvre la page ; la future se termine quand on revient sur le profil.
  final Future<void> Function() onOpen;

  @override
  State<SettingsHeroButton> createState() => _SettingsHeroButtonState();
}

class _SettingsHeroButtonState extends State<SettingsHeroButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: _kSlide);
  bool _busy = false;

  /// Vrai pendant que c'est le rond de l'overlay qu'on voit.
  bool _hidden = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    _busy = true;
    final from = box.localToGlobal(Offset.zero);
    _lastGear = from;
    final fly = _FlyingDisc(
      overlay: Overlay.of(context, rootOverlay: true),
      from: from,
      to: Offset(_kBackLeft, from.dy),
      reverse: false,
    );
    void tick() => fly.progress.value = _c.value;
    _c.addListener(tick);
    setState(() => _hidden = true);
    try {
      // 1. Le rond se déplace et arrive.
      await _c.forward(from: 0);
      // 2. Pose.
      await Future<void>.delayed(_kPause);
      // 3. La page s'ouvre en fondu, SOUS le rond.
      final closed = widget.onOpen();
      fly.bringToFront();
      await Future<void>.delayed(_kFade + const Duration(milliseconds: 40));
      // La page est là : son bouton retour est exactement sous le rond.
      fly.dispose();
      _c.removeListener(tick);
      _c.value = 0;
      if (mounted) setState(() => _hidden = false);
      await closed;
    } finally {
      _c.removeListener(tick);
      fly.dispose();
      if (mounted && _hidden) setState(() => _hidden = false);
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _go,
      child: Opacity(
        opacity: _hidden ? 0 : 1,
        child: const SettingsDisc(t: 0),
      ),
    );
  }
}

/// Le rond de verre (44). [t] 0 = engrenage, 1 = flèche retour ; entre les
/// deux, il roule (un demi-tour vers la gauche) et les icônes se fondent.
class SettingsDisc extends StatelessWidget {
  const SettingsDisc({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: SC.light ? SC.fill : Colors.white.withValues(alpha: 0.13),
              boxShadow: SC.lift,
              shape: BoxShape.circle,
              border: Border.all(
                color: SC.light ? SC.stroke : const Color(0x731F5EFF),
                width: 1.2,
              ),
            ),
            child: Transform.rotate(
              angle: -t * math.pi,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: (1 - t * 1.6).clamp(0.0, 1.0),
                    child: Icon(
                      Icons.settings_outlined,
                      size: 22,
                      color: SC.fg,
                    ),
                  ),
                  Opacity(
                    opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
                    // Contre-rotation : la flèche arrive à l'endroit.
                    child: Transform.rotate(
                      angle: t * math.pi,
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 22,
                        color: SC.fg,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le bouton retour des Réglages : le même rond, déjà en flèche, là où le rond
/// du profil vient de se poser. Au tap, l'effet inverse : il glisse jusqu'à la
/// place de l'engrenage en redevenant engrenage, s'y pose, PUIS la page se
/// referme en fondu sous lui — le rond ne disparaît qu'une fois le profil
/// revenu, pile sur l'engrenage identique.
class SettingsBackButton extends StatefulWidget {
  const SettingsBackButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  State<SettingsBackButton> createState() => _SettingsBackButtonState();
}

class _SettingsBackButtonState extends State<SettingsBackButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: _kSlide);
  bool _busy = false;
  bool _hidden = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    if (_busy) return;
    final gear = _lastGear;
    final box = context.findRenderObject() as RenderBox?;
    // Réglages ouverts d'ailleurs (pas depuis l'engrenage) : retour simple.
    if (gear == null || box == null) {
      widget.onTap?.call();
      return;
    }
    _busy = true;
    final from = box.localToGlobal(Offset.zero);
    final fly = _FlyingDisc(
      overlay: Overlay.of(context, rootOverlay: true),
      from: from,
      to: Offset(gear.dx, from.dy),
      reverse: true,
    );
    void tick() => fly.progress.value = _c.value;
    _c.addListener(tick);
    setState(() => _hidden = true);
    // 1. La flèche glisse jusqu'à l'engrenage.
    await _c.forward(from: 0);
    _c.removeListener(tick);
    fly.progress.value = 1;
    // 2. Pose.
    await Future<void>.delayed(_kPause);
    // 3. La page se referme en fondu SOUS le rond (cet écran est alors
    //    démonté : le rond de l'overlay ne dépend plus de lui).
    widget.onTap?.call();
    await Future<void>.delayed(_kFade + const Duration(milliseconds: 40));
    fly.dispose();
    if (mounted) {
      setState(() => _hidden = false);
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _back,
      child: Opacity(
        opacity: _hidden ? 0 : 1,
        child: const SettingsDisc(t: 1),
      ),
    );
  }
}
