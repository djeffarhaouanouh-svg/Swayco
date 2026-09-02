import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Discover globe — a spinning orthographic Earth used to pick a country, which
// the Discover feed then filters on (by the country's spoken language).
//
// Only the countries in [kGlobeCountries] are selectable. Everything else is
// drawn as context so the sphere reads as Earth, not two floating shapes.
// ══════════════════════════════════════════════════════════════════════════════

/// Selectable countries. `center` is (longitude, latitude) in degrees; `lang`
/// is the BCP-47 code the Discover feed filters on when this country is chosen.
const Map<String, ({String flag, Offset center, String lang})> kGlobeCountries = {
  'France': (flag: '🇫🇷', center: Offset(2.4, 46.6), lang: 'fr'),
  'Germany': (flag: '🇩🇪', center: Offset(10.3, 51.1), lang: 'de'),
};

/// The BCP-47 language a globe country key maps to, or null if it isn't one of
/// the selectable countries.
String? globeLangForCountry(String? key) =>
    key == null ? null : kGlobeCountries[key]?.lang;

/// Localised display name for a selectable country key (falls back to the key).
String globeCountryLabel(String key) {
  final lang = kGlobeCountries[key]?.lang;
  if (lang == null) return key;
  return AppStrings.t('country_$lang');
}

// ── GeoJSON world outline ────────────────────────────────────────────────────

class _Land {
  _Land(this.name, this.polygons) {
    // Rough centroid latitude of the first ring — enough to tint the fill by
    // climate band without a real area-weighted centroid.
    final ring = polygons.isNotEmpty && polygons.first.isNotEmpty
        ? polygons.first.first
        : const <Offset>[];
    if (ring.isEmpty) {
      avgLat = 0;
    } else {
      var s = 0.0;
      for (final p in ring) {
        s += p.dy;
      }
      avgLat = s / ring.length;
    }
  }

  final String name;

  /// polygon → ring → point, each point an Offset(longitude, latitude).
  final List<List<List<Offset>>> polygons;
  late final double avgLat;
}

/// Loads and caches `assets/geo/world-110m.geo.json` (Natural Earth 110m,
/// pre-converted to GeoJSON, coordinates rounded to 2 decimals).
class _WorldGeo {
  static List<_Land>? _cache;
  static Future<List<_Land>>? _inFlight;

  static Future<List<_Land>> load() {
    if (_cache != null) return Future.value(_cache);
    return _inFlight ??= _read();
  }

  static Future<List<_Land>> _read() async {
    final raw = await rootBundle.loadString('assets/geo/world-110m.geo.json');
    final fc = json.decode(raw) as Map<String, dynamic>;
    final out = <_Land>[];
    for (final f in (fc['features'] as List)) {
      final m = f as Map<String, dynamic>;
      final name = (m['properties'] as Map)['name']?.toString() ?? '';
      final g = m['geometry'] as Map<String, dynamic>;
      final type = g['type'];
      final coords = g['coordinates'] as List;
      final polys = <List<List<Offset>>>[];
      if (type == 'Polygon') {
        polys.add(_rings(coords));
      } else if (type == 'MultiPolygon') {
        for (final poly in coords) {
          polys.add(_rings(poly as List));
        }
      }
      if (polys.isNotEmpty) out.add(_Land(name, polys));
    }
    _cache = out;
    _inFlight = null;
    return out;
  }

  static List<List<Offset>> _rings(List rings) => [
        for (final r in rings)
          [
            for (final p in (r as List))
              Offset(
                (p[0] as num).toDouble(),
                (p[1] as num).toDouble(),
              ),
          ],
      ];
}

// ── Projection ──────────────────────────────────────────────────────────────

const double _deg = math.pi / 180;

/// Orthographic projection. [rotLon]/[rotLat] are the globe rotation in
/// degrees; returns null for points on the hidden hemisphere.
Offset? _project(
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
  if (z < 0) return null;
  return Offset(center.dx + x * radius, center.dy - y * radius);
}

/// Builds the screen-space path for one land feature at the given rotation.
/// A vertex on the hidden hemisphere lifts the pen; the next visible vertex
/// starts a fresh sub-path.
Path _landPath(
  _Land land,
  double rotLon,
  double rotLat,
  double radius,
  Offset center,
) {
  final path = Path();
  for (final poly in land.polygons) {
    for (final ring in poly) {
      var pen = false;
      for (final pt in ring) {
        final o = _project(pt.dx, pt.dy, rotLon, rotLat, radius, center);
        if (o == null) {
          pen = false;
          continue;
        }
        if (!pen) {
          path.moveTo(o.dx, o.dy);
          pen = true;
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
    }
  }
  return path;
}

/// Where each country's white label bubble floats, relative to its anchor
/// point on the globe (screen px, matches the prototype's `off`).
const Map<String, Offset> _kBubbleOffset = {
  'France': Offset(-42, 26),
  'Germany': Offset(38, -32),
};

const double _kBubbleR = 18;

/// Anchor (true geo point) + bubble centre for a selectable country, or null
/// when the country is on the hidden hemisphere.
({Offset anchor, Offset bubble})? _bubbleFor(
  String key,
  double rotLon,
  double rotLat,
  double radius,
  Offset center,
) {
  final c = kGlobeCountries[key]!.center;
  final a = _project(c.dx, c.dy, rotLon, rotLat, radius, center);
  if (a == null) return null;
  return (anchor: a, bubble: a + (_kBubbleOffset[key] ?? const Offset(0, -28)));
}

Color _terrain(double lat) {
  final a = lat.abs();
  if (a > 66) return const Color(0xFFF2F6F7);
  if (a > 55) return const Color(0xFFDFE7D6);
  if (a > 40) return const Color(0xFFD9E4CB);
  if (a > 30) return const Color(0xFFEAE3CD);
  if (a > 22) return const Color(0xFFEFE6CA);
  if (a > 12) return const Color(0xFFD5E3C2);
  return const Color(0xFFC9DFB6);
}

// ── The sheet ───────────────────────────────────────────────────────────────

/// Full-screen overlay: a dark card with the spinning globe and a cyan
/// "🔍 Lancer" button. Pops the set of selected country keys — never null:
/// an empty set (or a scrim/✕ dismiss) leaves the caller's filter untouched.
class DiscoverGlobeSheet extends StatefulWidget {
  const DiscoverGlobeSheet({super.key, this.initial = const {}});

  final Set<String> initial;

  @override
  State<DiscoverGlobeSheet> createState() => _DiscoverGlobeSheetState();
}

class _DiscoverGlobeSheetState extends State<DiscoverGlobeSheet> {
  List<_Land>? _world;
  late Set<String> _selected = {...widget.initial};

  @override
  void initState() {
    super.initState();
    _WorldGeo.load().then((w) {
      if (mounted) setState(() => _world = w);
    });
  }

  bool _transitionPrecached = false;

  void _toggle(String key) {
    HapticFeedback.selectionClick();
    setState(() {
      _selected = _selected.contains(key)
          ? (_selected.difference({key}))
          : ({..._selected, key});
    });
    // Fires the decode (JSON parse + the 88 embedded WebP frames) the moment
    // a country is picked, not when "Go" is tapped — by then the composition
    // is already sitting in lottie's sharedLottieCache, so the transition in
    // DiscoverScreen starts on its very first frame instead of a beat late.
    if (!_transitionPrecached) {
      _transitionPrecached = true;
      AssetLottie('assets/discover_filter_transition.json').load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canLaunch = _selected.isNotEmpty;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Scrim — assez léger pour laisser deviner le logo et la nav
          // autour du panneau ; tap pour fermer.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
          // Panneau : couvre la carte / la photo, mais laisse voir le logo en
          // haut et la barre de nav en bas. Le haut s'aligne PILE sous la
          // rangée du logo (~52) — sinon le bord de la carte dépasse au-dessus.
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 52, 14, 82),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141517),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFF26262D)),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 40,
                          offset: Offset(0, 18)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              AppStrings.t('globe_title'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).pop(),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.close_rounded,
                                  color: Color(0xFF9A9AA2), size: 22),
                            ),
                          ),
                        ],
                      ),
                      // Le globe occupe tout l'espace libre du panneau.
                      Expanded(
                        child: Center(
                          child: _world == null
                              ? const SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                      color: Colors.white24, strokeWidth: 2),
                                )
                              : LayoutBuilder(
                                  builder: (context, c) {
                                    final globeSide = math.min(
                                      math.min(c.maxWidth, c.maxHeight),
                                      520.0,
                                    );
                                    return SizedBox(
                                      width: globeSide,
                                      height: globeSide,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        clipBehavior: Clip.none,
                                        children: [
                                          // Lueur : halo cyan serré + brume
                                          // bleutée plus large.
                                          IgnorePointer(
                                            child: Container(
                                              width: globeSide * 0.92,
                                              height: globeSide * 0.92,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: SC.accent
                                                        .withValues(alpha: 0.34),
                                                    blurRadius: 42,
                                                    spreadRadius: -6,
                                                  ),
                                                  BoxShadow(
                                                    color: const Color(
                                                            0xFF7FA8BD)
                                                        .withValues(alpha: 0.20),
                                                    blurRadius: 85,
                                                    spreadRadius: -18,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          RepaintBoundary(
                                            child: _GlobeView(
                                              world: _world!,
                                              selected: _selected,
                                              onToggle: _toggle,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppStrings.t('globe_hint'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.42),
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                      // Le bouton n'apparaît qu'une fois un pays touché, et se
                      // pose en bas à DROITE — il ne prend pas toute la ligne.
                      if (canLaunch) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: _LaunchButton(
                            label:
                                '${_selected.map((k) => kGlobeCountries[k]!.flag).join(' - ')}'
                                '   ${AppStrings.t('globe_launch')}',
                            onTap: () => Navigator.of(context).pop(_selected),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LaunchButton extends StatelessWidget {
  const _LaunchButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // Ni `alignment` ni `width` : un Container avec `alignment` non nul
        // s'étire sur toute la largeur dispo (contraintes bornées) et le
        // bouton cesse d'être « à droite ». Le padding suffit à lui donner
        // sa forme de pilule autour du texte.
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
        decoration: BoxDecoration(
          color: SC.accent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF08080A),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── The interactive globe ───────────────────────────────────────────────────

class _GlobeView extends StatefulWidget {
  const _GlobeView({
    required this.world,
    required this.selected,
    required this.onToggle,
  });

  final List<_Land> world;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  State<_GlobeView> createState() => _GlobeViewState();
}

class _GlobeViewState extends State<_GlobeView> with TickerProviderStateMixin {
  double _rotLon = -12;
  double _rotLat = 12;
  double _scale = 1;

  bool _dragging = false;
  bool get _flying => _flyCtrl.isAnimating;

  // Inertie : vitesse résiduelle après un lâcher, en °/frame, amortie à
  // chaque tick jusqu'à retomber sur la rotation d'inactivité.
  double _velLon = 0, _velLat = 0;

  late final Ticker _spin;
  late final AnimationController _flyCtrl;
  double _flyFromLon = 0, _flyFromLat = 0, _flyToLon = 0, _flyToLat = 0;

  double _scaleStart = 1;

  @override
  void initState() {
    super.initState();
    _spin = createTicker(_onSpin)..start();
    _flyCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..addListener(_onFly);
    if (widget.selected.isNotEmpty) {
      // Land already on the first pre-selected country.
      final c = kGlobeCountries[widget.selected.first]!.center;
      _rotLon = -c.dx;
      _rotLat = c.dy;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _flyCtrl.dispose();
    super.dispose();
  }

  void _onSpin(Duration _) {
    if (_dragging || _flying) return;
    // Fling en cours : on glisse sur l'élan, amorti à ~0.93/frame.
    if (_velLon.abs() > 0.02 || _velLat.abs() > 0.02) {
      setState(() {
        _rotLon += _velLon;
        _rotLat = (_rotLat + _velLat).clamp(-82.0, 82.0);
        _velLon *= 0.93;
        _velLat *= 0.93;
      });
      return;
    }
    _velLon = _velLat = 0;
    if (widget.selected.isNotEmpty) return; // plus de rotation auto une fois choisi
    setState(() => _rotLon += 0.14);
  }

  void _onFly() {
    final t = Curves.easeOutCubic.transform(_flyCtrl.value);
    setState(() {
      _rotLon = _flyFromLon + (_flyToLon - _flyFromLon) * t;
      _rotLat = _flyFromLat + (_flyToLat - _flyFromLat) * t;
    });
  }

  void _flyTo(Offset center) {
    _velLon = _velLat = 0;
    _flyFromLon = _rotLon;
    _flyFromLat = _rotLat;
    // Shortest angular path — `_rotLon` may have wound up over many turns
    // while the globe auto-span; without this the fly-to whirls the long way.
    var delta = (-center.dx - _rotLon) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    _flyToLon = _rotLon + delta;
    _flyToLat = center.dy;
    _flyCtrl.forward(from: 0);
  }

  void _select(String key) {
    final adding = !widget.selected.contains(key);
    widget.onToggle(key);
    if (adding) _flyTo(kGlobeCountries[key]!.center);
  }

  void _handleTapUp(TapUpDetails d, Size size) {
    final radius = size.shortestSide / 2 - 8;
    final center = Offset(size.width / 2, size.height / 2);
    final r = radius * _scale;
    final p = d.localPosition;

    // The white label bubbles first — they're the easy target on small
    // countries.
    for (final key in kGlobeCountries.keys) {
      final b = _bubbleFor(key, _rotLon, _rotLat, r, center);
      if (b != null && (p - b.bubble).distance <= _kBubbleR + 4) {
        _select(key);
        return;
      }
    }
    // Then the country shapes themselves.
    for (final key in kGlobeCountries.keys) {
      final land = widget.world.firstWhere(
        (l) => l.name == key,
        orElse: () => _Land(key, const []),
      );
      if (land.polygons.isEmpty) continue;
      if (_landPath(land, _rotLon, _rotLat, r, center).contains(p)) {
        _select(key);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) {
            _dragging = true;
            _scaleStart = _scale;
            _velLon = _velLat = 0;
            _flyCtrl.stop();
          },
          onScaleUpdate: (d) {
            setState(() {
              if (d.scale != 1.0) {
                _scale = (_scaleStart * d.scale).clamp(1.0, 4.0);
              }
              // ~1:1 avec le doigt (0.42), plus fin quand on est zoomé.
              final k = 0.42 / _scale;
              final delta = d.focalPointDelta;
              _rotLon += delta.dx * k;
              _rotLat = (_rotLat + delta.dy * k).clamp(-82.0, 82.0);
            });
          },
          onScaleEnd: (d) {
            _dragging = false;
            // Reprend la vitesse du lâcher pour prolonger le mouvement.
            final v = d.velocity.pixelsPerSecond;
            _velLon = (v.dx * 0.007 / _scale).clamp(-9.0, 9.0);
            _velLat = (v.dy * 0.007 / _scale).clamp(-6.0, 6.0);
          },
          onTapUp: (d) => _handleTapUp(d, size),
          child: CustomPaint(
            size: size,
            painter: _GlobePainter(
              world: widget.world,
              selected: widget.selected,
              rotLon: _rotLon,
              rotLat: _rotLat,
              scale: _scale,
            ),
          ),
        );
      },
    );
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.world,
    required this.selected,
    required this.rotLon,
    required this.rotLat,
    required this.scale,
  });

  final List<_Land> world;
  final Set<String> selected;
  final double rotLon;
  final double rotLat;
  final double scale;

  static const _ocean = [Color(0xFFBFE0EF), Color(0xFFA4D0E6), Color(0xFF8BBEDB)];
  static const _selectedFill = Color(0xFF8EC06A);
  static const _pickableFill = Color(0xFFB6D59A);
  static const _border = Color(0xFFB9B3A3);
  static const _rim = Color(0xFF7FA8BD);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2 - 8) * scale;

    // Everything the globe draws stays inside its disc — keeps horizon
    // chords from the projection tucked behind the rim.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)));

    // Ocean.
    final oceanRect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.24, -0.36),
          radius: 0.95,
          colors: _ocean,
          stops: const [0.0, 0.62, 1.0],
        ).createShader(oceanRect),
    );

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = _border.withValues(alpha: 0.5);

    for (final land in world) {
      final path = _landPath(land, rotLon, rotLat, radius, center);
      final isCountry = kGlobeCountries.containsKey(land.name);
      final isSelected = selected.contains(land.name);
      final Color fill;
      if (isSelected) {
        fill = _selectedFill;
      } else if (isCountry) {
        fill = _pickableFill;
      } else {
        fill = _terrain(land.avgLat);
      }
      canvas.drawPath(path, Paint()..color = fill);
      canvas.drawPath(path, borderPaint);
      if (isCountry && !isSelected) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = SC.accent.withValues(alpha: 0.75),
        );
      }
    }

    canvas.restore();

    // Rim.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = _rim.withValues(alpha: 0.8),
    );

    // ── White label bubbles (FR / DE) — outside the clip so they can float
    //    over the rim, like the prototype's pins. ─────────────────────────
    for (final key in kGlobeCountries.keys) {
      final b = _bubbleFor(key, rotLon, rotLat, radius, center);
      if (b == null) continue;
      final picked = selected.contains(key);

      // Connector.
      canvas.drawLine(
        b.anchor,
        b.bubble,
        Paint()
          ..color = const Color(0x8A3D3A33)
          ..strokeWidth = 1.6,
      );
      // Anchor dot on the true location.
      canvas.drawCircle(b.anchor, 4, Paint()..color = SC.accent);
      canvas.drawCircle(
        b.anchor,
        4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white,
      );
      // Bubble shadow + white disc.
      canvas.drawCircle(
        b.bubble.translate(0, 2),
        _kBubbleR,
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawCircle(b.bubble, _kBubbleR, Paint()..color = Colors.white);
      canvas.drawCircle(
        b.bubble,
        _kBubbleR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = picked ? 2 : 1
          ..color = picked ? SC.accent : const Color(0xFFC9C2B2),
      );
      // Country code.
      final tp = TextPainter(
        text: TextSpan(
          text: kGlobeCountries[key]!.lang.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF1B1B1F),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, b.bubble - Offset(tp.width / 2, tp.height / 2));
      // Small cyan accent dot on the bubble's shoulder.
      final acc = b.bubble + const Offset(13, -13);
      canvas.drawCircle(acc, 4.5, Paint()..color = SC.accent);
      canvas.drawCircle(
        acc,
        4.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_GlobePainter old) =>
      old.rotLon != rotLon ||
      old.rotLat != rotLat ||
      old.scale != scale ||
      old.selected.length != selected.length ||
      !old.selected.containsAll(selected) ||
      !identical(old.world, world);
}
