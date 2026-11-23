import 'dart:math' as math;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import 'profile_avatar.dart' show ProfileAvatar;
import 'viewport_trigger.dart';

const Color _kYellow = Color(0xFFF4FF1F);
const Color _kCyan = Color(0xFF22D3EE);
const double _kLoopMs = 8000;

/// Un petit rond de drapeau (vrai drapeau, pas un emoji : Windows n'affiche pas
/// les drapeaux emoji).
Widget _flag(String iso, double size) {
  if (iso.isEmpty) return SizedBox(width: size, height: size);
  return ClipOval(
    child: CountryFlag.fromCountryCode(
      iso,
      theme: ImageTheme(width: size, height: size, shape: const Circle()),
    ),
  );
}

/// L'exemple « Appelle avec traduction en direct » du guide de l'équipe : une
/// miniature ANIMÉE de l'écran d'appel (boucle de 8 s). Elle montre qui parle
/// (des ondes cyan seulement autour de TOI) et les 4 étapes de la traduction.
///
/// Les deux personnes sont accordées à leur photo et à leur drapeau :
///  • toi : ta vraie photo de profil, le drapeau de ton pays ;
///  • l'autre : Aiko et le Japon — ou, si tu es toi-même japonais, Minji et la
///    Corée du Sud (pour que la traduction serve à quelque chose).
class GuideCallExample extends StatefulWidget {
  const GuideCallExample({
    super.key,
    required this.myName,
    required this.myAvatarUrl,
    required this.myIso,
    required this.peerName,
    required this.peerIso,
    required this.youSays,
    required this.peerSays,
  });

  final String myName;
  final String myAvatarUrl;

  /// ISO2 (minuscules) du drapeau de ma personne ET de ma pastille de langue.
  final String myIso;

  final String peerName;
  final String peerIso;

  /// Ma phrase (dans ma langue) et celle de l'autre (dans la sienne).
  final String youSays;
  final String peerSays;

  @override
  State<GuideCallExample> createState() => _GuideCallExampleState();
}

class _GuideCallExampleState extends State<GuideCallExample>
    with TickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 8000),
  );
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  bool _started = false;

  /// La boucle ne démarre que quand la carte est à l'écran.
  void _start() {
    if (_started || !mounted) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _loop.value = 4800 / _kLoopMs; // l'étape 3, figée
      return;
    }
    _loop.repeat();
    _ring.repeat();
    _spin.repeat();
  }

  @override
  void dispose() {
    _loop.dispose();
    _ring.dispose();
    _spin.dispose();
    super.dispose();
  }

  /// Opacité d'une fenêtre [a, b] (ms), avec un fondu de [f] ms à chaque bord.
  double _win(double t, double a, double b, {double f = 240}) {
    final i = ((t - a) / f).clamp(0.0, 1.0);
    final o = ((b - t) / f).clamp(0.0, 1.0);
    return math.min(i, o);
  }

  @override
  Widget build(BuildContext context) {
    return OnVisible(
      onVisible: _start,
      child: AspectRatio(
        // Un peu plus haut que 4/3 : la carte du bas ne touche pas les prénoms.
        aspectRatio: 1.2,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1B2250), Color(0xFF0B0E22)],
              ),
            ),
            child: AnimatedBuilder(
              animation: _loop,
              builder: (context, _) {
                final t = _loop.value * _kLoopMs;
                final youTalk = math.max(_win(t, 240, 1760), _win(t, 6240, 7680));
                final peerGot = _win(t, 4240, 5760);
                final waiting = _win(t, 2240, 3760);
                return Stack(
                  children: [
                    Positioned(top: 8, right: 8, child: _liveBadge()),
                    Positioned(
                      left: 34,
                      top: 46,
                      child: _person(
                        label: widget.peerName,
                        name: widget.peerName,
                        avatarUrl: '',
                        iso: widget.peerIso,
                        ring: 0,
                        border: Color.lerp(
                          Colors.white.withValues(alpha: 0.35),
                          _kYellow,
                          peerGot,
                        )!,
                      ),
                    ),
                    Positioned(
                      right: 34,
                      top: 46,
                      child: _person(
                        label: AppStrings.t('official_guide_you'),
                        name: widget.myName,
                        avatarUrl: widget.myAvatarUrl,
                        iso: widget.myIso,
                        ring: youTalk,
                        border: Color.lerp(
                          Colors.white.withValues(alpha: 0.7),
                          _kCyan,
                          youTalk,
                        )!,
                      ),
                    ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 14,
                      child: _card(t, waiting),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _liveBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(99),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate_rounded, size: 11, color: Colors.white70),
            SizedBox(width: 4),
            Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      );

  /// Un portrait : la photo (ou l'initiale sur sa couleur) ET le drapeau du pays
  /// de CETTE personne, son prénom dessous.
  Widget _person({
    required String label,
    required String name,
    required String avatarUrl,
    required String iso,
    required double ring,
    required Color border,
  }) {
    const size = 60.0;
    return SizedBox(
      width: size,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (ring > 0) _rings(size, ring),
                Container(
                  width: size,
                  height: size,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: border, width: 2),
                  ),
                  child: ProfileAvatar(
                    displayName: name,
                    avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
                    size: size - 8,
                  ),
                ),
                Positioned(
                  right: -6,
                  bottom: -4,
                  child: Container(
                    width: 26,
                    height: 26,
                    padding: const EdgeInsets.all(1.5),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF16205A),
                    ),
                    child: _flag(iso, 23),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  /// Les ondes de l'appel traduit : 3 anneaux cyan 1,5 px, échelle 0,6 à 1,6,
  /// opacité 0,8 à 0, 2,4 s, décalés de 0,8 s (comme l'écran d'appel).
  Widget _rings(double size, double visible) => Opacity(
        opacity: visible,
        child: AnimatedBuilder(
          animation: _ring,
          builder: (context, _) => Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                () {
                  final p = (_ring.value + i / 3) % 1.0;
                  final e = Curves.easeOut.transform(p);
                  return Opacity(
                    opacity: (1 - e) * 0.8,
                    child: Transform.scale(
                      scale: 0.6 + e,
                      child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: _kCyan, width: 1.5),
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          ),
        ),
      );

  Widget _card(double t, double waiting) {
    final s1 = _win(t, 0, 1760, f: 200);
    final s2 = _win(t, 2240, 3760, f: 200);
    final s3 = _win(t, 4240, 5760, f: 200);
    final s4 = _win(t, 6240, 7680, f: 200);
    final you = _win(t, 480, 1760, f: 200);
    final peer = _win(t, 4320, 7680, f: 200);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.26)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Opacity(opacity: 1 - 0.6 * waiting, child: _miniOrb()),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 20,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      _status(AppStrings.t('tuto_tr_l1'), s1, Colors.white),
                      _status(AppStrings.t('tuto_tr_l2'), s2, Colors.white),
                      _status(
                        AppStrings.t(
                          'tuto_tr_l3',
                          args: {'name': widget.peerName},
                        ),
                        s3,
                        Colors.white,
                      ),
                      _status(AppStrings.t('tuto_tr_l4'), s4, _kYellow),
                    ],
                  ),
                ),
              ),
              // La pastille de langue : UN seul drapeau, le mien (le même que
              // sur mon portrait) — jamais celui de l'autre.
              Container(
                height: 28,
                padding: const EdgeInsets.fromLTRB(6, 0, 4, 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _flag(widget.myIso, 20),
                    const Icon(Icons.unfold_more_rounded,
                        size: 17, color: Colors.white),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 26,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                _line(widget.youSays, you, Colors.white,
                    name: widget.myName, avatarUrl: widget.myAvatarUrl),
                _line(widget.peerSays, peer, Colors.white.withValues(alpha: 0.85),
                    name: widget.peerName, avatarUrl: ''),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _status(String text, double o, Color c) => Opacity(
        opacity: o,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w700),
        ),
      );

  Widget _line(
    String text,
    double o,
    Color c, {
    required String name,
    required String avatarUrl,
  }) =>
      Opacity(
        opacity: o,
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.6), width: 1.5),
              ),
              child: ProfileAvatar(
                displayName: name,
                avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: c, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );

  /// Le galet de 30 px de la carte d'appel (rotation continue).
  Widget _miniOrb() => SizedBox(
        width: 30,
        height: 30,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  Color(0x8000BFFF),
                  Color(0x407C3AED),
                  Color(0x00000000),
                ], stops: [0.0, 0.55, 1.0]),
              ),
            ),
            RotationTransition(
              turns: _spin,
              child: Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: [
                    Color(0xFFFF0080),
                    Color(0xFFFF8C00),
                    Color(0xFFFFEF00),
                    Color(0xFF00FF87),
                    Color(0xFF00BFFF),
                    Color(0xFF7C3AED),
                    Color(0xFFFF0080),
                  ]),
                ),
              ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
                gradient: RadialGradient(
                  center: const Alignment(-0.3, -0.4),
                  colors: [
                    Colors.white.withValues(alpha: 0.6),
                    Colors.white.withValues(alpha: 0.16),
                    const Color(0x590A0F1C),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ],
        ),
      );
}
