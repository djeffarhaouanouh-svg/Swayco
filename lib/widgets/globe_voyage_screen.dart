part of 'discover_globe.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Animation « voyage multi-pays » : jouée plein écran entre « Lancer » (pop-up
// Globe) et l'affichage des cartes filtrées. Un seul AnimationController ; tout
// se déduit du temps `t` (en secondes). Un appui saute l'animation.
// ══════════════════════════════════════════════════════════════════════════════

/// Joue l'animation puis se ferme toute seule. Ne montre rien (rend aussitôt)
/// quand les animations sont réduites ou qu'il n'y a aucun pays.
Future<void> playGlobeVoyage(BuildContext context, Set<String> keys) async {
  final picked = [
    for (final k in keys)
      if (kGlobeCountries.containsKey(k)) k,
  ].take(4).toList();
  if (picked.isEmpty || MediaQuery.disableAnimationsOf(context)) return;
  Analytics.track('globe_voyage_play', props: {'n': picked.length});
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => GlobeVoyageScreen(countries: picked),
    ),
  );
}

class GlobeVoyageScreen extends StatefulWidget {
  const GlobeVoyageScreen({super.key, required this.countries});

  /// Clés de [kGlobeCountries], 1 à 4.
  final List<String> countries;

  @override
  State<GlobeVoyageScreen> createState() => _GlobeVoyageScreenState();
}

class _GlobeVoyageScreenState extends State<GlobeVoyageScreen>
    with SingleTickerProviderStateMixin {
  // ── Le minutage (secondes) ─────────────────────────────────────────────────
  static const double _intro = 0.8;
  static const double _step = 1.0;
  static const double _travel = 0.55;
  static const double _planeDur = 2.1;

  late final int _n = widget.countries.length;
  late final double _stopsEnd = _intro + _n * _step + 0.2; // « Ls »
  late final double _planeStart = _stopsEnd + 0.3;
  late final double _total = _planeStart + _planeDur + 0.4;

  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_total * 1000).round()),
  );

  List<_Land>? _world;
  bool _closed = false;

  /// Longitude / latitude du centre du globe au départ.
  static const Offset _start = Offset(-25, 12);

  @override
  void initState() {
    super.initState();
    _WorldGeo.load().then((w) {
      if (!mounted) return;
      setState(() => _world = w);
      // L'horloge ne part qu'une fois la carte chargée : aucune escale perdue.
      _ctl.forward();
    });
    _ctl.addStatusListener((s) {
      if (s == AnimationStatus.completed) _close();
    });
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Offset _centerOf(int i) => kGlobeCountries[widget.countries[i]]!.center;

  /// Centre du globe (lon, lat) et zoom à l'instant [t].
  ({double lon, double lat, double zoom}) _view(double t) {
    var lon = _start.dx;
    var lat = _start.dy;
    var zoom = 1.0;
    for (var i = 0; i < _n; i++) {
      final s = _intro + i * _step;
      if (t < s) break;
      final from = i == 0 ? _start : _centerOf(i - 1);
      final to = _centerOf(i);
      final p = ((t - s) / _travel).clamp(0.0, 1.0);
      final e = Curves.easeInOutCubic.transform(p);
      var d = to.dx - from.dx;
      while (d > 180) {
        d -= 360;
      }
      while (d < -180) {
        d += 360;
      }
      lon = from.dx + d * e;
      lat = from.dy + (to.dy - from.dy) * e;
      zoom = 1 - 0.07 * math.sin(math.pi * p);
    }
    lon += 2.5 * math.sin(1.2 * t);
    return (lon: lon, lat: lat, zoom: zoom);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final k = size.width / 390;
    final light = SC.light;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Analytics.track('globe_voyage_skip');
          _close();
        },
        child: AnimatedBuilder(
          animation: _ctl,
          builder: (context, _) {
            final t = _ctl.value * _total;
            final fadeOut = t > _total - 0.4
                ? ((_total - t) / 0.4).clamp(0.0, 1.0)
                : 1.0;
            return Opacity(
              opacity: fadeOut,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.2, 0.1),
                        radius: 1.0,
                        colors: light
                            ? const [
                                Color(0xFFCFE0FF),
                                Color(0xFFEAF2FF),
                                Color(0xFFFFFFFF),
                              ]
                            : const [
                                Color(0xFF1F4FD6),
                                Color(0xFF0F1A3A),
                                Color(0xFF0A0F1C),
                              ],
                        stops: const [0, 0.55, 1],
                      ),
                    ),
                  ),
                  if (_world != null)
                    CustomPaint(
                      size: size,
                      painter: _VoyagePainter(
                        world: _world!,
                        keys: widget.countries,
                        t: t,
                        view: _view(t),
                        k: k,
                        intro: _intro,
                        step: _step,
                        travel: _travel,
                        planeStart: _planeStart,
                        stopsEnd: _stopsEnd,
                      ),
                    ),
                  ..._labels(t, size, k),
                  _plane(t, size, k, light),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Étiquette « drapeau + pays » à chaque escale.
  List<Widget> _labels(double t, Size size, double k) {
    final out = <Widget>[];
    final top = MediaQuery.paddingOf(context).top;
    for (var i = 0; i < _n; i++) {
      final arrive = _intro + i * _step + _travel;
      final tau = t - arrive;
      if (tau < 0 || tau > 0.8) continue;
      final inP = Curves.easeOut.transform((tau / 0.25).clamp(0.0, 1.0));
      final outP = tau < 0.55 ? 1.0 : (1 - (tau - 0.55) / 0.25).clamp(0.0, 1.0);
      final key = widget.countries[i];
      final c = kGlobeCountries[key]!;
      final cy = size.height / 2 + 100 * k;
      final y = math.max(top + 24, cy - 388 * k);
      out.add(
        Positioned(
          left: 0,
          right: 0,
          top: y + 10 * (1 - inP),
          child: Opacity(
            opacity: inP * outP,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: SC.accent,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: SC.accent.withValues(alpha: 0.55),
                      blurRadius: 24,
                      spreadRadius: -4,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipOval(
                      child: Image.network(
                        'https://flagcdn.com/w80/${c.code}.png',
                        width: 15,
                        height: 15,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Text(
                          c.flag,
                          style: const TextStyle(fontSize: 13, height: 1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      AppStrings.t('country_${c.code}'),
                      style: popupDisplay(fontSize: 14, color: SC.onAccent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return out;
  }

  /// L'avion de profil qui traverse l'écran, avec son ombre et sa traînée.
  Widget _plane(double t, Size size, double k, bool light) {
    final tt = ((t - _planeStart) / _planeDur).clamp(0.0, 1.0);
    if (t < _planeStart || tt >= 1) return const SizedBox.shrink();
    final u = 0.6 * tt + 0.4 * Curves.easeInOutQuad.transform(tt);
    final cx = (-380 + (770 - -380) * u) * k;
    final cy = (450 - 40 * u) * k;
    final w = 580 * k;
    final vk = 580 / 620; // viewBox 620 -> 580
    final h = 240 * vk * k;
    // Position d'un point (x, y) de la viewBox -300 -140 620 240.
    Offset at(double x, double y) =>
        Offset((x + 300) * vk * k, (y + 140) * vk * k);
    // Dans le SVG, y est la LIGNE DE BASE du texte : la boite Flutter est
    // centree, donc on remonte son centre d'environ 0,35 em.
    final swaycSize = 50 * vk * k;
    final dotSize = 34 * vk * k;
    final swayc = at(-6, 19).translate(0, -0.35 * swaycSize);
    final dot = at(-218, -79).translate(0, -0.35 * dotSize);
    final ink = const Color(0xFF04123A);
    final shadowColor =
        light ? const Color(0x661F5EFF) : const Color(0x8C02143C);
    Widget textAt(Offset p, Widget child) => Positioned(
          left: p.dx,
          top: p.dy,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: child,
          ),
        );
    final plane = SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SvgPicture.asset(
            'assets/swayco_plane_profil.svg',
            width: w,
            height: h,
          ),
          textAt(
            swayc,
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'swayc', style: TextStyle(color: ink)),
                  const TextSpan(
                    text: 'ø',
                    style: TextStyle(color: Color(0xFF1F5EFF)),
                  ),
                ],
                style: TextStyle(
                  fontFamily: SC.brandFont,
                  fontWeight: FontWeight.w700,
                  fontSize: swaycSize,
                  letterSpacing: 1.5 * vk * k,
                ),
              ),
              softWrap: false,
            ),
          ),
          textAt(
            dot,
            Text(
              'ø',
              softWrap: false,
              style: TextStyle(
                fontFamily: SC.brandFont,
                fontWeight: FontWeight.w700,
                fontSize: dotSize,
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );
    final shadow = ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: SvgPicture.asset(
        'assets/swayco_plane_profil.svg',
        width: w,
        height: h,
        colorFilter: ColorFilter.mode(shadowColor, BlendMode.srcIn),
      ),
    );
    // Traînee : une bande blanche qui s'efface vers l'arriere.
    final trailLen = 340 * k;
    final trailY = at(0, 58).dy;
    final trail = Positioned(
      left: -trailLen,
      top: trailY - 6 * k,
      width: trailLen,
      height: 12 * k,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12 * k),
          gradient: const LinearGradient(
            colors: [Color(0x00FFFFFF), Color(0xD9FFFFFF)],
          ),
        ),
      ),
    );
    return Positioned(
      left: cx - w / 2,
      top: cy - h / 2,
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 90 * k,
            child: shadow,
          ),
          trail,
          Positioned(left: 0, top: 0, child: plane),
        ],
      ),
    );
  }
}

/// Le globe : océan bleu, terres, méridiens, pays visités en jaune, grand arc
/// en pointillés entre deux escales, onde d'arrivée.
class _VoyagePainter extends CustomPainter {
  _VoyagePainter({
    required this.world,
    required this.keys,
    required this.t,
    required this.view,
    required this.k,
    required this.intro,
    required this.step,
    required this.travel,
    required this.planeStart,
    required this.stopsEnd,
  });

  final List<_Land> world;
  final List<String> keys;
  final double t;
  final ({double lon, double lat, double zoom}) view;
  final double k;
  final double intro;
  final double step;
  final double travel;
  final double planeStart;
  final double stopsEnd;

  static const _land = Color(0xFF3768EA);

  /// Projection qui ne perd jamais un point : sur la face cachée, il retombe
  /// sur le bord du disque (le pays est « coupé » au limbe).
  static Offset _limb(
    double lon,
    double lat,
    double rotLon,
    double rotLat,
    double radius,
    Offset center,
  ) {
    final l = (lon + rotLon) * _deg;
    final p = lat * _deg;
    final r0 = rotLat * _deg;
    final cosP = math.cos(p);
    final x = cosP * math.sin(l);
    final y = math.cos(r0) * math.sin(p) - math.sin(r0) * cosP * math.cos(l);
    final z = math.sin(r0) * math.sin(p) + math.cos(r0) * cosP * math.cos(l);
    if (z >= 0) return Offset(center.dx + x * radius, center.dy - y * radius);
    final n = math.sqrt(x * x + y * y);
    if (n < 1e-6) return center;
    return Offset(center.dx + x / n * radius, center.dy - y / n * radius);
  }

  /// Vrai si un point (lon, lat) est sur la face visible.
  static bool _visible(double lon, double lat, double rotLon, double rotLat) {
    final l = (lon + rotLon) * _deg;
    final p = lat * _deg;
    final r0 = rotLat * _deg;
    final z = math.sin(r0) * math.sin(p) +
        math.cos(r0) * math.cos(p) * math.cos(l);
    return z >= 0;
  }

  Path _landPathLimb(
    _Land land,
    double rotLon,
    double rotLat,
    double radius,
    Offset center,
  ) {
    final path = Path();
    for (final poly in land.polygons) {
      for (final ring in poly) {
        var any = false;
        for (final pt in ring) {
          if (_visible(pt.dx, pt.dy, rotLon, rotLat)) {
            any = true;
            break;
          }
        }
        if (!any) continue; // tout le contour est derriere : rien a dessiner
        var first = true;
        for (final pt in ring) {
          final o = _limb(pt.dx, pt.dy, rotLon, rotLat, radius, center);
          if (first) {
            path.moveTo(o.dx, o.dy);
            first = false;
          } else {
            path.lineTo(o.dx, o.dy);
          }
        }
        path.close();
      }
    }
    return path;
  }

  static List<double> _unit(double lon, double lat) {
    final lo = lon * _deg;
    final la = lat * _deg;
    return [
      math.cos(la) * math.cos(lo),
      math.cos(la) * math.sin(lo),
      math.sin(la),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final lift = Curves.easeOutCubic
        .transform(((t - (stopsEnd + 0.2)) / 1.0).clamp(0.0, 1.0));
    final radius = 350 * k * view.zoom * (1 - 0.3 * lift);
    final center = Offset(
      size.width / 2,
      size.height / 2 + 100 * k - 120 * k * lift,
    );
    final rotLon = -view.lon;
    final rotLat = view.lat;
    final disc = Rect.fromCircle(center: center, radius: radius);

    // Halo jaune autour du globe.
    canvas.drawCircle(
      center,
      radius + 5,
      Paint()
        ..color = SC.accent.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 45),
    );
    canvas.drawCircle(
      center,
      radius + 2,
      Paint()
        ..color = SC.accent.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(disc));

    // Océan.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.35),
          radius: 1.0,
          colors: [Color(0xFF2A5BE0), Color(0xFF15399F), Color(0xFF0B1F5C)],
          stops: [0, 0.55, 1],
        ).createShader(disc),
    );

    // Parallèles et méridiens (blanc 8 %).
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.08);
    final gridPath = Path();
    void polyline(Iterable<Offset> pts, List<bool> vis) {
      var pen = false;
      var i = 0;
      for (final p in pts) {
        if (!vis[i]) {
          pen = false;
        } else if (!pen) {
          gridPath.moveTo(p.dx, p.dy);
          pen = true;
        } else {
          gridPath.lineTo(p.dx, p.dy);
        }
        i++;
      }
    }

    for (var la = -60; la <= 60; la += 30) {
      final pts = <Offset>[];
      final vis = <bool>[];
      for (var lo = -180; lo <= 180; lo += 6) {
        vis.add(_visible(lo.toDouble(), la.toDouble(), rotLon, rotLat));
        pts.add(_limb(lo.toDouble(), la.toDouble(), rotLon, rotLat, radius, center));
      }
      polyline(pts, vis);
    }
    for (var lo = -180; lo < 180; lo += 30) {
      final pts = <Offset>[];
      final vis = <bool>[];
      for (var la = -90; la <= 90; la += 6) {
        vis.add(_visible(lo.toDouble(), la.toDouble(), rotLon, rotLat));
        pts.add(_limb(lo.toDouble(), la.toDouble(), rotLon, rotLat, radius, center));
      }
      polyline(pts, vis);
    }
    canvas.drawPath(gridPath, grid);

    // Terres (sans l'Antarctique) ; les pays du voyage passent en jaune.
    final landFill = Paint()..color = _land;
    final landStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withValues(alpha: 0.22);
    for (final land in world) {
      if (land.name == 'Antarctica') continue;
      final path = _landPathLimb(land, rotLon, rotLat, radius, center);
      canvas.drawPath(path, landFill);
      canvas.drawPath(path, landStroke);
      final i = keys.indexOf(land.name);
      if (i >= 0) {
        final reached = intro + i * step + travel;
        final a = ((t - reached) / 0.4).clamp(0.0, 1.0);
        if (a > 0) {
          canvas.drawPath(
            path,
            Paint()..color = SC.accent.withValues(alpha: a),
          );
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = Colors.white.withValues(alpha: a),
          );
        }
      }
    }

    // Ombrage de la sphère : blanc 8 % -> transparent -> bleu nuit 60 %.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.35),
          radius: 1.05,
          colors: [Color(0x14FFFFFF), Color(0x00000000), Color(0x99040A1E)],
          stops: [0, 0.55, 1],
        ).createShader(disc),
    );

    // Arcs en pointillés entre deux pays consécutifs.
    for (var i = 1; i < keys.length; i++) {
      final s = intro + i * step;
      final q = ((t - s) / travel).clamp(0.0, 1.0);
      if (q <= 0) continue;
      final a = kGlobeCountries[keys[i - 1]]!.center;
      final b = kGlobeCountries[keys[i]]!.center;
      final ua = _unit(a.dx, a.dy);
      final ub = _unit(b.dx, b.dy);
      final dot = (ua[0] * ub[0] + ua[1] * ub[1] + ua[2] * ub[2]).clamp(-1.0, 1.0);
      final om = math.acos(dot);
      if (om < 1e-4) continue;
      final so = math.sin(om);
      final arc = Path();
      var pen = false;
      const n = 64;
      for (var j = 0; j <= n; j++) {
        final f = q * j / n;
        final w1 = math.sin((1 - f) * om) / so;
        final w2 = math.sin(f * om) / so;
        final x = w1 * ua[0] + w2 * ub[0];
        final y = w1 * ua[1] + w2 * ub[1];
        final z = w1 * ua[2] + w2 * ub[2];
        final lat = math.asin(z.clamp(-1.0, 1.0)) / _deg;
        final lon = math.atan2(y, x) / _deg;
        final o = _project(lon, lat, rotLon, rotLat, radius, center);
        if (o == null) {
          pen = false;
          continue;
        }
        if (!pen) {
          arc.moveTo(o.dx, o.dy);
          pen = true;
        } else {
          arc.lineTo(o.dx, o.dy);
        }
      }
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = SC.accent.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      final dash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = SC.accent;
      final dashed = Path();
      for (final m in arc.computeMetrics()) {
        for (var d = 0.0; d < m.length; d += 8) {
          dashed.addPath(m.extractPath(d, math.min(d + 0.1, m.length)), Offset.zero);
        }
      }
      canvas.drawPath(dashed, glow);
      canvas.drawPath(dashed, dash);
    }

    canvas.restore();

    // Onde d'arrivée sur chaque pays, au centre du globe.
    for (var i = 0; i < keys.length; i++) {
      final arrive = intro + i * step + travel;
      final tau = t - arrive;
      if (tau < 0 || tau > 0.7) continue;
      final f = tau / 0.7;
      final r = (0.4 + 1.6 * f) * 60 * k;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = SC.accent.withValues(alpha: (1 - f).clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(_VoyagePainter old) =>
      old.t != t || !identical(old.world, world);
}
