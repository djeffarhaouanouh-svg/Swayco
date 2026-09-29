import 'dart:convert';
import 'dart:math' as math;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A country's outline filled with its flag — the bubbles of the Discover
/// country row. The outline comes from the same Natural Earth file as the
/// globe (`assets/geo/world-110m.geo.json`); only the country's LARGEST
/// polygon is kept, so France is the hexagon without French Guiana and
/// Sweden without Gotland.
///
/// The flag is stretched over the whole outline (never cropped): it fills the
/// silhouette's bounding box, so Brazil's rhombus stays whole.
class CountrySilhouette extends StatefulWidget {
  const CountrySilhouette({
    super.key,
    required this.geoName,
    required this.iso2,
    this.size = 28,
  });

  /// Feature name in the GeoJSON (English, e.g. 'Spain').
  final String geoName;

  /// ISO-3166-1 alpha-2 code of the flag to paint (e.g. 'es').
  final String iso2;

  /// Side of the square the outline is fitted into.
  final double size;

  @override
  State<CountrySilhouette> createState() => _CountrySilhouetteState();
}

class _CountrySilhouetteState extends State<CountrySilhouette> {
  List<Offset>? _ring;

  @override
  void initState() {
    super.initState();
    _OutlineCache.ring(widget.geoName).then((r) {
      if (mounted) setState(() => _ring = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final ring = _ring;
    if (ring == null || ring.length < 3) return SizedBox(width: s, height: s);
    final fitted = _fit(ring, s);
    // Trois couches pour que le pays fasse corps avec sa bulle au lieu d'y
    // flotter comme un autocollant : une ombre douce sous la forme, le
    // drapeau découpé dedans, puis un liseré sombre qui en dessine le bord.
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _ShadowPainter(fitted.path)),
          ),
          ClipPath(
            clipper: _PathClipper(fitted.path),
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: fitted.bounds,
                  child: FittedBox(
                    fit: BoxFit.fill,
                    child: CountryFlag.fromCountryCode(
                      widget.iso2,
                      theme: const ImageTheme(width: 40, height: 30),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: CustomPaint(painter: _OutlinePainter(fitted.path)),
          ),
        ],
      ),
    );
  }

  /// Projects (lon, lat) to screen with an equirectangular projection scaled
  /// by cos(latitude) — enough at country scale — then fits the result into
  /// an [s]×[s] square, centred, aspect ratio preserved.
  static ({Path path, Rect bounds}) _fit(List<Offset> ring, double s) {
    var sumLat = 0.0;
    for (final p in ring) {
      sumLat += p.dy;
    }
    final k = math.cos((sumLat / ring.length) * math.pi / 180);
    final pts = [for (final p in ring) Offset(p.dx * k, -p.dy)];
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final w = maxX - minX, h = maxY - minY;
    final scale = s / math.max(w, h);
    final dx = (s - w * scale) / 2, dy = (s - h * scale) / 2;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = Offset(
        dx + (pts[i].dx - minX) * scale,
        dy + (pts[i].dy - minY) * scale,
      );
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    path.close();
    return (
      path: path,
      bounds: Rect.fromLTWH(dx, dy, w * scale, h * scale),
    );
  }
}

/// L'ombre portée de la silhouette, légèrement décalée vers le bas : la forme
/// se pose DANS la bulle.
class _ShadowPainter extends CustomPainter {
  _ShadowPainter(this.path);
  final Path path;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      path.shift(const Offset(0, 1.2)),
      Paint()
        ..color = const Color(0x8C000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
    );
  }

  @override
  bool shouldRepaint(_ShadowPainter old) => old.path != path;
}

/// Le liseré qui dessine le bord du pays — sans lui, le blanc et le jaune des
/// drapeaux se perdent sur le gris de la bulle.
class _OutlinePainter extends CustomPainter {
  _OutlinePainter(this.path);
  final Path path;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0x59000000),
    );
  }

  @override
  bool shouldRepaint(_OutlinePainter old) => old.path != path;
}

class _PathClipper extends CustomClipper<Path> {
  _PathClipper(this.path);
  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_PathClipper old) => old.path != path;
}

/// Reads the GeoJSON once and keeps, per requested country, the outer ring of
/// its largest polygon.
class _OutlineCache {
  static Map<String, dynamic>? _geo;
  static Future<Map<String, dynamic>>? _loading;
  static final Map<String, List<Offset>?> _rings = {};

  static Future<List<Offset>?> ring(String name) async {
    if (_rings.containsKey(name)) return _rings[name];
    final geo = _geo ?? await (_loading ??= _load());
    List<Offset>? best;
    var bestArea = 0.0;
    for (final f in geo['features'] as List) {
      final m = f as Map<String, dynamic>;
      if ((m['properties'] as Map)['name'] != name) continue;
      final g = m['geometry'] as Map<String, dynamic>;
      final coords = g['coordinates'] as List;
      final polys = g['type'] == 'Polygon' ? [coords] : coords;
      for (final poly in polys) {
        final outer = [
          for (final p in (poly as List).first as List)
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
        ];
        final a = _area(outer);
        if (a > bestArea) {
          bestArea = a;
          best = outer;
        }
      }
    }
    return _rings[name] = best;
  }

  static Future<Map<String, dynamic>> _load() async {
    final raw = await rootBundle.loadString('assets/geo/world-110m.geo.json');
    return _geo = json.decode(raw) as Map<String, dynamic>;
  }

  static double _area(List<Offset> r) {
    var a = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      a += p.dx * q.dy - q.dx * p.dy;
    }
    return a.abs() / 2;
  }
}
