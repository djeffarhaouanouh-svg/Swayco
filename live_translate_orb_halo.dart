import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Barre live avec l'orbe traducteur "Halo" (option 1b), taille réduite.
///
/// - Actif : anneau spectral qui tourne, noyau sombre, cœur clair qui se déforme.
/// - Tap : coupé -> extinction douce (désaturation partielle), animations figées.
/// - `onPeerSpeaking()` : l'orbe s'agite, onde de choc, et glisse à droite en
///   effaçant le chevron et le raccroché ; retour automatique après [returnDelay].
/// - Non cliquable pendant le glissement.
class LiveTranslateBarHalo extends StatefulWidget {
  const LiveTranslateBarHalo({
    super.key,
    this.transcript = 'Pokemon is…',
    this.peerInitial = 'L',
    this.returnDelay = const Duration(seconds: 2),
    this.slideDistance = 94,
    this.orbSize = 46,
    this.onMutedChanged,
    this.onHangUp,
    this.onExpand,
    this.onCollapse,
  });

  final String transcript;
  final String peerInitial;
  final Duration returnDelay;
  final double slideDistance;

  /// 46 par défaut (était 52). Les icônes latérales suivent la même réduction.
  final double orbSize;

  final ValueChanged<bool>? onMutedChanged;
  final VoidCallback? onHangUp;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;

  @override
  State<LiveTranslateBarHalo> createState() => LiveTranslateBarHaloState();
}

class LiveTranslateBarHaloState extends State<LiveTranslateBarHalo>
    with TickerProviderStateMixin {
  double get _orb => widget.orbSize;
  double get _side => widget.orbSize - 7; // 39 pour un orbe de 46
  double get _avatar => widget.orbSize - 15;

  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  )..repeat();
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5000),
  )..repeat();
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final AnimationController _shock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  bool _muted = false;
  bool _speaking = false;
  StreamSubscription<void>? _idle;

  /// À appeler quand le VAD détecte que l'interlocuteur parle.
  void onPeerSpeaking() {
    if (_muted) return;
    setState(() => _speaking = true);
    _breathe.repeat(reverse: true);
    _shock.repeat();
    _setSpeed(true);
    _idle?.cancel();
    _idle = Future.delayed(widget.returnDelay).asStream().listen((_) {
      if (!mounted) return;
      setState(() => _speaking = false);
      _breathe
        ..stop()
        ..value = 0;
      _shock.stop();
      _setSpeed(false);
    });
  }

  void _setSpeed(bool fast) {
    _halo.duration = Duration(milliseconds: fast ? 1500 : 3400);
    _morph.duration = Duration(milliseconds: fast ? 2200 : 5000);
    if (!_muted) {
      _halo.repeat();
      _morph.repeat();
    }
  }

  void _toggleMute() {
    if (_speaking) return; // non cliquable en position glissée
    setState(() => _muted = !_muted);
    widget.onMutedChanged?.call(_muted);
    if (_muted) {
      _halo.stop();
      _morph.stop();
    } else {
      _halo.repeat();
      _morph.repeat();
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    _halo.dispose();
    _morph.dispose();
    _breathe.dispose();
    _shock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slid = _speaking && !_muted;
    final lane = _orb + 2 * (_side + 8); // orbe + chevron + raccroché
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF17171B),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF24242C)),
      ),
      child: Row(
        children: [
          Expanded(child: _transcriptPill()),
          const SizedBox(width: 11),
          SizedBox(
            width: lane,
            height: _orb,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _sideButton(
                  left: _orb + 8,
                  hidden: slid,
                  background: const Color(0xFF3A3A44),
                  onTap: widget.onCollapse,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded,
                      size: 20, color: Color(0xFFE8E8F0)),
                ),
                _sideButton(
                  left: _orb + _side + 16,
                  hidden: slid,
                  background: const Color(0xFFE8342C),
                  onTap: widget.onHangUp,
                  icon: Transform.rotate(
                    angle: 133 * math.pi / 180,
                    child: const Icon(Icons.phone, size: 18, color: Colors.white),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOutExpo,
                  left: slid ? widget.slideDistance : 0,
                  top: 0,
                  child: _orbButton(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _transcriptPill() => Container(
        padding: const EdgeInsets.only(left: 7, right: 9, top: 7, bottom: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF232329),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Container(
              width: _avatar,
              height: _avatar,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: Color(0xFF0F9D76), shape: BoxShape.circle),
              child: Text(widget.peerInitial,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(widget.transcript,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFD6D6DE), fontSize: 14)),
            ),
            GestureDetector(
              onTap: widget.onExpand,
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.keyboard_arrow_up_rounded,
                    size: 17, color: Color(0x8CD6D6DE)),
              ),
            ),
          ],
        ),
      );

  Widget _sideButton({
    required double left,
    required bool hidden,
    required Color background,
    required Widget icon,
    VoidCallback? onTap,
  }) =>
      Positioned(
        left: left,
        top: (_orb - _side) / 2,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 450),
          scale: hidden ? 0.6 : 1,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 350),
            opacity: hidden ? 0 : 1,
            child: GestureDetector(
              onTap: hidden ? null : onTap,
              child: Container(
                width: _side,
                height: _side,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: background, shape: BoxShape.circle),
                child: icon,
              ),
            ),
          ),
        ),
      );

  Widget _orbButton() {
    return GestureDetector(
      onTap: _toggleMute,
      child: SizedBox(
        width: _orb,
        height: _orb,
        child: AnimatedBuilder(
          animation: Listenable.merge([_halo, _morph, _breathe, _shock]),
          builder: (context, _) {
            final breathe = 1 + 0.08 * math.sin(_breathe.value * math.pi);
            final glow = _muted ? 0.0 : (_speaking ? 1.0 : 0.75);
            final core = _orb - 18; // cœur clair

            final orb = Transform.scale(
              scale: _speaking ? breathe : 1,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // Anneau spectral rotatif
                  Opacity(
                    opacity: glow,
                    child: Transform.rotate(
                      angle: _halo.value * 2 * math.pi,
                      child: Container(
                        width: _orb + 6,
                        height: _orb + 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(colors: [
                            Color(0xFF7EE8FF),
                            Color(0xFF6B7BFF),
                            Color(0xFFC08CFF),
                            Color(0xFFFFFFFF),
                            Color(0xFF7EE8FF),
                          ]),
                        ),
                      ),
                    ),
                  ),
                  // Noyau sombre
                  Container(
                    width: _orb,
                    height: _orb,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: Alignment(0, -0.25),
                        radius: 0.85,
                        colors: [Color(0xFF232333), Color(0xFF0A0A12)],
                      ),
                      boxShadow: [
                        BoxShadow(
                            color: Color(0xA6000000),
                            blurRadius: 22,
                            offset: Offset(0, 8)),
                      ],
                    ),
                  ),
                  // Cœur clair qui se déforme
                  Container(
                    width: core,
                    height: core,
                    decoration: BoxDecoration(
                      borderRadius: _morphRadius(_morph.value, core),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFE8ECFF), Color(0xFF8F9DFF)],
                      ),
                    ),
                  ),
                  // Onde de choc pendant la parole
                  if (_speaking)
                    Opacity(
                      opacity: (1 - _shock.value).clamp(0, 1) * 0.7,
                      child: Container(
                        width: (_orb + 8) * (0.8 + 1.2 * _shock.value),
                        height: (_orb + 8) * (0.8 + 1.2 * _shock.value),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: const Color(0x8096A8FF), width: 1),
                        ),
                      ),
                    ),
                ],
              ),
            );

            // Extinction douce : désaturation partielle + léger assombrissement
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(end: _muted ? 1 : 0),
              duration: const Duration(milliseconds: 750),
              curve: Curves.easeInOutCubic,
              builder: (context, m, child) => ColorFiltered(
                colorFilter: ColorFilter.matrix(_softMute(m)),
                child: child,
              ),
              child: orb,
            );
          },
        ),
      ),
    );
  }

  /// Désature à 72 % et assombrit à 82 % quand m = 1.
  List<double> _softMute(double m) {
    final s = 1 - 0.72 * m;
    final b = 1 - 0.18 * m;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    return <double>[
      (lr + s * (1 - lr)) * b, (lg - lg * s) * b, (lb - lb * s) * b, 0, 0,
      (lr - lr * s) * b, (lg + s * (1 - lg)) * b, (lb - lb * s) * b, 0, 0,
      (lr - lr * s) * b, (lg - lg * s) * b, (lb + s * (1 - lb)) * b, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Rayons interpolés : le cœur passe du rond au galet déformé.
  BorderRadius _morphRadius(double t, double size) {
    final r = size / 2;
    double lerp(double a, double b, double k) => a + (b - a) * k;
    final keys = <List<double>>[
      [r, r, r, r],
      [r * 1.24, r * 0.76, r * 0.9, r * 1.1],
      [r * 0.8, r * 1.2, r * 1.16, r * 0.84],
      [r, r, r, r],
    ];
    final seg = (t * 3).clamp(0, 2.999);
    final i = seg.floor();
    final k = Curves.easeInOut.transform(seg - i);
    final a = keys[i], b = keys[i + 1];
    return BorderRadius.only(
      topLeft: Radius.circular(lerp(a[0], b[0], k)),
      topRight: Radius.circular(lerp(a[1], b[1], k)),
      bottomRight: Radius.circular(lerp(a[2], b[2], k)),
      bottomLeft: Radius.circular(lerp(a[3], b[3], k)),
    );
  }
}
