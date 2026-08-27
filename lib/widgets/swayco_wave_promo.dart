// swayco_wave_promo.dart — carte d'onboarding "Faire signe" à afficher
// au-dessus de la barre de navigation, sur la liste des messages. Montrée
// une seule fois, à la toute première ouverture de l'écran Messages.
//
// Les avatars du bas sont les vraies PDP des conversations existantes (pas
// des initiales de démo) : le même [ProfileAvatar] que partout ailleurs
// dans l'app, donc la même photo ou la même couleur-lettre de repli.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import 'profile_avatar.dart';

const List<Color> kWavePromoOrbColors = [
  Color(0xFFFF0080),
  Color(0xFFFF8C00),
  Color(0xFFFFEF00),
  Color(0xFF00FF87),
  Color(0xFF00BFFF),
  Color(0xFF7C3AED),
  Color(0xFFFF0080), // boucle sans couture
];

/// Le groupe du bas montre toujours ce nombre de ronds — les vraies
/// conversations d'abord, complétées par des ronds de couleur démo (sans
/// initiale : ils ne miment personne de réel) tant qu'il n'y en a pas assez.
const int _kSlotCount = 4;
const List<Color> _kDemoFillColors = [
  Color(0xFFFF8C00),
  Color(0xFF00BFFF),
  Color(0xFF00FF87),
  Color(0xFF7C3AED),
];

/// Un pair à faire apparaître dans l'animation — sa vraie PDP (ou repli
/// initiale) via [ProfileAvatar].
class WavePromoPeer {
  const WavePromoPeer({required this.avatarUrl, required this.displayName});
  final String avatarUrl;
  final String displayName;
}

class SwaycoWavePromo extends StatefulWidget {
  const SwaycoWavePromo({
    super.key,
    required this.peers,
    this.onCta,
    this.onDismiss,
  });

  /// Jusqu'à 4 conversations existantes, les plus récentes en premier.
  final List<WavePromoPeer> peers;

  final VoidCallback? onCta;
  final VoidCallback? onDismiss;

  @override
  State<SwaycoWavePromo> createState() => _SwaycoWavePromoState();
}

class _SwaycoWavePromoState extends State<SwaycoWavePromo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4600),
  )..repeat();

  /// Verrouille la croix / « Pas maintenant » jusqu'à ce qu'un cycle complet
  /// se soit joué — impossible de sortir avant d'avoir vu la démo en entier.
  bool _locked = true;

  @override
  void initState() {
    super.initState();
    Future.delayed(_c.duration!, () {
      if (mounted) setState(() => _locked = false);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _tryDismiss() {
    if (_locked) return;
    widget.onDismiss?.call();
  }

  /// Interpolation eased sur une liste de [position 0..1, valeur].
  static double _stops(double t, List<List<double>> kf) {
    if (t <= kf.first[0]) return kf.first[1];
    for (var i = 0; i < kf.length - 1; i++) {
      final a = kf[i], b = kf[i + 1];
      if (t >= a[0] && t <= b[0]) {
        final span = b[0] - a[0];
        final k = span == 0 ? 0.0 : (t - a[0]) / span;
        return a[1] + (b[1] - a[1]) * Curves.easeInOut.transform(k);
      }
    }
    return kf.last[1];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;

        final glow = _stops(t, [
          [0.00, 0.10],
          [0.20, 0.10],
          [0.34, 0.30],
          [0.60, 0.16],
          [1.00, 0.16],
        ]);

        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF1F2226)),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF101114), Color(0xFF08080A)],
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Lueur aux couleurs de l'orbe, diffusée jusqu'aux bords.
              Positioned(
                top: -82,
                left: 0,
                right: 0,
                child: Center(
                  child: Opacity(
                    opacity: glow,
                    child: ImageFiltered(
                      imageFilter:
                          ui.ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                      child: Container(
                        width: 320,
                        height: 320,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(colors: kWavePromoOrbColors),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 26, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 150, child: _stage(t)),
                    const SizedBox(height: 14),
                    // Comme la croix : inerte tant que le cycle complet
                    // n'est pas joué. Ce CTA ne fait signe à personne en
                    // particulier — le laisser fermer l'overlay avant la
                    // fin reviendrait à contourner le verrou.
                    AnimatedOpacity(
                      opacity: _locked ? 0.35 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: _cta(),
                    ),
                    const SizedBox(height: 8),
                    AnimatedOpacity(
                      opacity: _locked ? 0.35 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: GestureDetector(
                        onTap: _tryDismiss,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 9, horizontal: 16),
                          child: Text(
                            AppStrings.t('call_promo_not_now'),
                            style: const TextStyle(
                                color: Color(0xFF8A8F96), fontSize: 13.5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Croix dans l'angle — inerte tant que le cycle complet n'est
              // pas joué : impossible de fuir la démo avant la fin.
              Positioned(
                top: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _locked ? 0.35 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: GestureDetector(
                    onTap: _tryDismiss,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFF17181B),
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(14),
                        ),
                      ),
                      child: const Icon(Icons.close,
                          size: 17, color: Color(0xFF9AA0A8)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stage(double t) {
    // Bouton : appuyé à 26 %, rebond à 34 %.
    final btnScale = _stops(t, [
      [0.00, 1.0],
      [0.20, 1.0],
      [0.26, 0.90],
      [0.34, 1.10],
      [0.44, 1.0],
      [1.00, 1.0],
    ]);
    // Main qui s'agite juste après l'appui.
    final waveDeg = _stops(t, [
      [0.24, 0],
      [0.30, -18],
      [0.36, 16],
      [0.42, -10],
      [0.48, 0],
      [1.00, 0],
    ]);
    // Onde jaune qui se propage.
    final ringScale = _stops(t, [
      [0.24, 0.7],
      [0.30, 1.0],
      [0.50, 2.1],
      [1.00, 2.1],
    ]);
    final ringOp = _stops(t, [
      [0.24, 0],
      [0.30, 0.7],
      [0.50, 0],
      [1.00, 0],
    ]);
    // Doigt qui descend puis se retire.
    final fingerY = _stops(t, [
      [0.00, -4],
      [0.08, -4],
      [0.22, -36],
      [0.26, -30],
      [0.40, -34],
      [1.00, -30],
    ]);
    final fingerOp = _stops(t, [
      [0.00, 0],
      [0.08, 1],
      [0.40, 1],
      [0.52, 0],
      [1.00, 0],
    ]);
    // Pastille de statut.
    final statusOp = _stops(t, [
      [0.34, 0],
      [0.42, 1],
      [0.92, 1],
      [1.00, 0],
    ]);
    final statusY = _stops(t, [
      [0.34, 6],
      [0.42, 0],
      [1.00, 0],
    ]);

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        // Bouton 👋 + onde + doigt
        Positioned(
          top: 0,
          child: SizedBox(
            width: 78,
            height: 78,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Transform.scale(
                  scale: ringScale,
                  child: Opacity(
                    opacity: ringOp,
                    child: Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFFFFEF00), width: 2),
                      ),
                    ),
                  ),
                ),
                Transform.scale(
                  scale: btnScale,
                  child: Container(
                    width: 66,
                    height: 66,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF33343A)),
                    ),
                    child: Transform.rotate(
                      angle: waveDeg * 3.14159 / 180,
                      alignment: const Alignment(0.4, 0.6),
                      child: const Text('👋',
                          style: TextStyle(fontSize: 30)),
                    ),
                  ),
                ),
                Positioned(
                  top: 78 + fingerY,
                  child: Opacity(
                    opacity: fingerOp,
                    child:
                        const Text('👆', style: TextStyle(fontSize: 26)),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Pastille de statut.
        Positioned(
          top: 88 + statusY,
          child: Opacity(
            opacity: statusOp,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF0E1A13),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFF1F5A3A)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF00FF87),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    AppStrings.t('wave_promo_status'),
                    style: const TextStyle(
                      color: Color(0xFFC9F5DE),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 4 places : les vraies conversations d'abord, puis des ronds de
        // couleur démo (aucune identité) pour compléter le groupe quand il
        // y a moins de 4 conversations.
        Positioned(
          bottom: 0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _kSlotCount; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                i < widget.peers.length
                    ? _peer(widget.peers[i], t, 0.46 + i * 0.06)
                    : _demoPeer(
                        _kDemoFillColors[i % _kDemoFillColors.length],
                        t,
                        0.46 + i * 0.06,
                      ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _peer(WavePromoPeer p, double t, double start) {
    final op = _stops(t, [
      [start, 0],
      [start + 0.08, 1],
      [0.92, 1],
      [1.00, 0],
    ]);
    final sc = _stops(t, [
      [start, 0.7],
      [start + 0.08, 1],
      [1.00, 1],
    ]);
    final dy = _stops(t, [
      [start, 8],
      [start + 0.08, 0],
      [1.00, 0],
    ]);

    return Opacity(
      opacity: op,
      child: Transform.translate(
        offset: Offset(0, dy),
        child: Transform.scale(
          scale: sc,
          child: ProfileAvatar(
            displayName: p.displayName,
            avatarUrl: p.avatarUrl,
            size: 34,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  /// Rond de remplissage — une couleur démo, aucune initiale : il complète
  /// le groupe sans faire croire à une conversation qui n'existe pas.
  Widget _demoPeer(Color color, double t, double start) {
    final op = _stops(t, [
      [start, 0],
      [start + 0.08, 1],
      [0.92, 1],
      [1.00, 0],
    ]);
    final sc = _stops(t, [
      [start, 0.7],
      [start + 0.08, 1],
      [1.00, 1],
    ]);
    final dy = _stops(t, [
      [start, 8],
      [start + 0.08, 0],
      [1.00, 0],
    ]);

    return Opacity(
      opacity: op,
      child: Transform.translate(
        offset: Offset(0, dy),
        child: Transform.scale(
          scale: sc,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
      ),
    );
  }

  Widget _cta() {
    return GestureDetector(
      onTap: _locked ? null : widget.onCta,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF33343A)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('👋', style: TextStyle(fontSize: 17)),
            const SizedBox(width: 10),
            Text(
              AppStrings.t('wave_promo_cta'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
