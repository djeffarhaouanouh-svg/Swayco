part of 'discover_globe.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Globe zoomé : bulles photo par pays (6a) puis par ville (6b).
//
// Des widgets posés PAR-DESSUS le dessin du globe, à l'endroit où chaque pays /
// ville se projette : leurs photos ne se chargent donc que pour les bulles
// visibles (12 au plus), et le toucher passe par un simple GestureDetector.
// ─────────────────────────────────────────────────────────────────────────────

/// 1 234 -> « 1,2 k » ; sous 1 000, le nombre exact.
String _shortCount(int n) {
  if (n < 1000) return '$n';
  final k = n / 1000;
  var s = k >= 10 ? k.round().toString() : k.toStringAsFixed(1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  if (AppStrings.currentBcp47.value == 'fr') s = s.replaceAll('.', ',');
  return '$s k';
}

/// Une bulle photo : photo ronde cerclée de blanc, drapeau en haut à droite
/// (pays), compteur en bas, nom à droite (ville). Choisie = bord jaune + halo.
class _ZoomBubble extends StatelessWidget {
  const _ZoomBubble({
    required this.diameter,
    required this.photoUrl,
    required this.count,
    this.flagCode,
    this.selected = false,
    this.label,
    this.labelOpacity = 1,
  });

  final double diameter;
  final String? photoUrl;
  final int count;
  final String? flagCode;
  final bool selected;
  final String? label;
  final double labelOpacity;

  @override
  Widget build(BuildContext context) {
    final d = diameter;
    final url = photoUrl;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: url == null ? SC.brandGradient : null,
              border: Border.all(
                color: selected ? SC.accent : Colors.white,
                width: selected ? 3.5 : 2.5,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: SC.accent.withValues(alpha: 0.35),
                        spreadRadius: 3,
                      ),
                      BoxShadow(
                        color: SC.accent.withValues(alpha: 0.7),
                        blurRadius: 22,
                      ),
                    ]
                  : const [
                      BoxShadow(
                        color: Color(0x8004123A),
                        blurRadius: 12,
                        offset: Offset(0, 6),
                      ),
                    ],
            ),
            child: ClipOval(
              child: url == null
                  ? const SizedBox.expand()
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      cacheWidth: (d * 2).round(),
                      errorBuilder: (_, _, _) => DecoratedBox(
                        decoration: BoxDecoration(gradient: SC.brandGradient),
                      ),
                    ),
            ),
          ),
        ),
        if (flagCode != null)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: ClipOval(
                child: Image.network(
                  'https://flagcdn.com/w80/${flagCode!.toLowerCase()}.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        if (count > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: -7,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: selected ? SC.accent : const Color(0xD904123A),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _shortCount(count),
                  maxLines: 1,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: selected ? const Color(0xFF04123A) : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        if (label != null)
          Positioned(
            left: d + 6,
            top: 0,
            bottom: 0,
            width: 150,
            child: Opacity(
              opacity: labelOpacity.clamp(0.0, 1.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label!,
                  maxLines: 1,
                  softWrap: false,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF04123A),
                    shadows: const [
                      Shadow(color: Colors.white, blurRadius: 4),
                      Shadow(color: Colors.white, blurRadius: 4),
                      Shadow(color: Color(0xE6FFFFFF), blurRadius: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

extension _GlobeZoomLayer on _GlobeViewState {
  /// Les bulles à poser maintenant, selon le niveau de zoom :
  ///  · < 1,4  : rien (les bulles blanches du dessin) ;
  ///  · 1,4–2,6 : une bulle photo par pays ouvert (12 au plus) ;
  ///  · > 2,6  : le pays au centre (ou le pays choisi) se divise en villes.
  List<Widget> _zoomBubbles(Size size) {
    if (_scale < 1.4) return const [];
    final r = (size.shortestSide / 2 - 8) * _scale;
    final center = Offset(size.width / 2, size.height / 2);
    final d6a = (46 + (_scale - 1.4) * 8).clamp(46.0, 56.0).toDouble();

    // Pays visibles, les plus proches du centre du globe d'abord.
    final cands = <({String key, Offset at, double dist})>[];
    for (final key in kGlobeCountries.keys) {
      final c = kGlobeCountries[key]!.center;
      final at = _project(c.dx, c.dy, _rotLon, _rotLat, r, center);
      if (at == null) continue;
      cands.add((key: key, at: at, dist: (at - center).distance));
    }
    cands.sort((a, b) => a.dist.compareTo(b.dist));
    final shown = cands.take(12).toList();

    // Le pays qui se divise : le choisi s'il est là, sinon celui du milieu.
    String? focus;
    if (widget.selected.isNotEmpty) {
      final last = widget.selected.last;
      if (shown.any((c) => c.key == last)) focus = last;
    }
    focus ??= shown.isEmpty ? null : shown.first.key;

    // Villes du pays au centre (niveau 6b).
    final cities = <({CityBubble city, Offset at, double d})>[];
    if (_scale > 2.6 && focus != null) {
      final threshold = _scale > 3.3 ? 2 : 3;
      final list = GlobePlaces.cities(focus)
          .where((c) => c.count >= threshold)
          .toList();
      if (list.isNotEmpty) {
        final minC = list.map((c) => c.count).reduce(math.min);
        final maxC = list.map((c) => c.count).reduce(math.max);
        final placed = <({CityBubble city, Offset at, double d})>[];
        for (final c in list) {
          final at = _project(c.lon, c.lat, _rotLon, _rotLat, r, center);
          if (at == null) continue;
          final d = maxC == minC
              ? 57.0
              : 48 + 18 * (c.count - minC) / (maxC - minC);
          // Deux bulles qui se touchent : on garde la plus peuplée (la liste
          // est triée par effectif décroissant).
          if (placed.any((p) => (p.at - at).distance < (p.d + d) / 2)) continue;
          placed.add((city: c, at: at, d: d));
        }
        cities.addAll(placed);
      }
    }
    _scheduleSplit(cities.isEmpty ? null : focus);
    final t = Curves.easeOutCubic.transform(_splitCtl.value);

    final out = <Widget>[];
    for (final c in shown) {
      final splitting = cities.isNotEmpty && c.key == focus;
      if (splitting) continue;
      final info = kGlobeCountries[c.key]!;
      final stat = GlobePlaces.country(c.key);
      out.add(
        Positioned(
          key: ValueKey('country-${c.key}'),
          left: c.at.dx - d6a / 2,
          top: c.at.dy - d6a / 2,
          width: d6a,
          height: d6a,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _select(c.key),
            child: _ZoomBubble(
              diameter: d6a,
              photoUrl: stat?.photoUrl,
              count: stat?.count ?? 0,
              flagCode: info.code,
              selected: widget.selected.contains(c.key),
            ),
          ),
        ),
      );
    }
    if (cities.isNotEmpty && focus != null) {
      final from = shown.firstWhere((c) => c.key == focus).at;
      for (final c in cities) {
        final at = Offset.lerp(from, c.at, t)!;
        final d = c.d * (0.35 + 0.65 * t);
        final bounce = _bounceKey == c.city.name
            ? 1 + 0.12 * math.sin(math.pi * _bounceCtl.value)
            : 1.0;
        out.add(
          Positioned(
            key: ValueKey('city-$focus-${c.city.name}'),
            left: at.dx - d / 2,
            top: at.dy - d / 2,
            width: d,
            height: d,
            child: Transform.scale(
              scale: bounce,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Une ville ne se choisit pas : elle montre où sont les gens.
                onTap: () => _bounce(c.city.name),
                child: _ZoomBubble(
                  diameter: d,
                  photoUrl: c.city.photoUrl,
                  count: c.city.count,
                  label: c.city.name,
                  labelOpacity: t,
                ),
              ),
            ),
          ),
        );
      }
    }
    return out;
  }
}
