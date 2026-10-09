import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';

import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/swayco_sounds.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

part 'globe_voyage_screen.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Discover globe — a spinning orthographic Earth used to pick a country. The
// Discover feed filters on the peer's actual `profiles.country`, regardless of
// what they speak — that's the whole point (a Québécois and a Parisian both
// speak French but are not "elsewhere" from each other the way the app means).
//
// Only the countries in [kGlobeCountries] are selectable. Everything else is
// drawn as context so the sphere reads as Earth, not two floating shapes.
// ══════════════════════════════════════════════════════════════════════════════

/// Selectable countries. `center` is (longitude, latitude) in degrees. `code`
/// is the ISO2 shown on the bubble. `dbName` is the EXACT string stored in
/// `profiles.country` (`lib/services/locations.dart`'s `kCountries`) — not
/// always the same as the map key, e.g. `'Germany'` (key) vs `'Allemagne'`
/// (dbName) — and is what's actually sent to the Discover feed as a filter.
const Map<String, ({String flag, Offset center, String code, String dbName})>
kGlobeCountries = {
  'France': (flag: '🇫🇷', center: Offset(2.4, 46.6), code: 'fr', dbName: 'France'),
  'Germany': (flag: '🇩🇪', center: Offset(10.3, 51.1), code: 'de', dbName: 'Allemagne'),
  'Canada': (flag: '🇨🇦', center: Offset(-96.5, 62.4), code: 'ca', dbName: 'Canada'),
  'Japan': (flag: '🇯🇵', center: Offset(138.3, 36.3), code: 'jp', dbName: 'Japon'),
  'Belgium': (flag: '🇧🇪', center: Offset(4.5, 50.6), code: 'be', dbName: 'Belgique'),
  'Brazil': (flag: '🇧🇷', center: Offset(-53.1, -10.8), code: 'br', dbName: 'Brésil'),
  // Added with the Discover country row (FR · ES · BR · SE · MA).
  'Spain': (flag: '🇪🇸', center: Offset(-3.7, 40.2), code: 'es', dbName: 'Espagne'),
  'Sweden': (flag: '🇸🇪', center: Offset(16.0, 62.5), code: 'se', dbName: 'Suède'),
  'Morocco': (flag: '🇲🇦', center: Offset(-6.3, 31.8), code: 'ma', dbName: 'Maroc'),
};

/// The `profiles.country` value a globe country key maps to, or null if it
/// isn't one of the selectable countries. This is what the Discover feed
/// filters on — see [kGlobeCountries]'s `dbName`.
String? globeCountryDbName(String? key) =>
    key == null ? null : kGlobeCountries[key]?.dbName;

/// Localised display name for a selectable country key (falls back to the
/// key). Unused today (no call sites) — only `country_fr`/`country_de` exist
/// in AppStrings; add `country_ca`/`country_jp`/`country_be`/`country_br`
/// (12 locales) before wiring this up for the 4 newer countries.
String globeCountryLabel(String key) {
  final code = kGlobeCountries[key]?.code;
  if (code == null) return key;
  return AppStrings.t('country_$code');
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
  // Best-effort placement for the 4 new countries — not visually tuned on a
  // running globe (no device/simulator in the session that added them).
  // Check these on a real build and adjust if a bubble overlaps its own
  // country shape or another bubble.
  'Canada': Offset(-46, -34),
  'Japan': Offset(34, 10),
  'Belgium': Offset(30, 24),
  'Brazil': Offset(-40, 30),
  // Same caveat for these three (Discover country row).
  'Spain': Offset(-44, 8),
  'Sweden': Offset(-8, -40),
  'Morocco': Offset(-40, 22),
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

/// Qui je veux rencontrer : choisi sur la page 2 du globe, appliqué au deck
/// Discover (`profile.gender` : m / f).
enum GenderFilter { homme, femme, mixte }

/// Ce que renvoie la pop-up Globe : les pays ET le genre.
typedef GlobeResult = ({Set<String> countries, GenderFilter gender});

// ── The sheet ───────────────────────────────────────────────────────────────

/// Full-screen overlay: a dark card with the spinning globe and a cyan
/// "🔍 Lancer" button. Pops the set of selected country keys — never null:
/// an empty set (or a scrim/✕ dismiss) leaves the caller's filter untouched.
class DiscoverGlobeSheet extends StatefulWidget {
  const DiscoverGlobeSheet({
    super.key,
    this.initial = const {},
    this.initialGender = GenderFilter.mixte,
  });

  final Set<String> initial;
  final GenderFilter initialGender;

  @override
  State<DiscoverGlobeSheet> createState() => _DiscoverGlobeSheetState();
}

class _DiscoverGlobeSheetState extends State<DiscoverGlobeSheet>
    with SingleTickerProviderStateMixin {
  List<_Land>? _world;
  late Set<String> _selected = {...widget.initial};

  /// 1 = les pays (globe), 2 = « Qui veux-tu y rencontrer ? ».
  int _page = 1;
  late GenderFilter _gender = widget.initialGender;

  /// Toute la transition page 1 -> 2 sur UN contrôleur (1,2 s).
  late final AnimationController _pageCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  /// Le globe descend, rétrécit et s'éteint sur les 950 premières ms.
  late final Animation<double> _globeT = _pageCtl.drive(
    CurveTween(
      curve: const Interval(0, 0.79, curve: Cubic(0.65, 0, 0.25, 1)),
    ),
  );

  /// La page 1 (croix, recherche, titre) s'efface sur 400 ms.
  late final Animation<double> _p1T = _pageCtl.drive(
    CurveTween(curve: const Interval(0, 400 / 1200, curve: Curves.easeOut)),
  );

  final GlobalKey<_GlobeViewState> _globeKey = GlobalKey<_GlobeViewState>();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _WorldGeo.load().then((w) {
      if (mounted) setState(() => _world = w);
    });
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _pageCtl.dispose();
    super.dispose();
  }

  bool _transitionPrecached = false;

  void _toggle(String key) {
    HapticFeedback.selectionClick();
    setState(() {
      _selected = _selected.contains(key)
          ? (_selected.difference({key}))
          : ({..._selected, key});
    });
    // Plus aucun pays choisi depuis la page 2 : retour à la page 1.
    if (_selected.isEmpty && _page == 2) _setPage(1);
    // Fires the decode (JSON parse + the 88 embedded WebP frames) the moment
    // a country is picked, not when "Go" is tapped — by then the composition
    // is already sitting in lottie's sharedLottieCache, so the transition in
    // DiscoverScreen starts on its very first frame instead of a beat late.
    if (!_transitionPrecached) {
      _transitionPrecached = true;
      AssetLottie('assets/discover_filter_transition.json').load();
    }
  }

  /// Nom affiché d'un pays : sa traduction `country_xx`, sinon sa clé.
  String _nameOf(String key) {
    final code = kGlobeCountries[key]!.code;
    final t = AppStrings.t('country_$code');
    return t == 'country_$code' ? key : t;
  }

  /// Pays dont le nom (traduit ou non) contient ce qui est tapé.
  List<String> get _matches {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final key in kGlobeCountries.keys)
        if (_nameOf(key).toLowerCase().contains(q) ||
            key.toLowerCase().contains(q))
          key,
    ];
  }

  /// Un résultat de recherche : le pays est choisi et le globe y vole.
  void _pickFromSearch(String key) {
    if (!_selected.contains(key)) _toggle(key);
    _globeKey.currentState?.flyToCountry(key);
    _search.clear();
    _searchFocus.unfocus();
  }

  /// Passe d'une page à l'autre : le globe tourne de 40° pendant le trajet.
  void _setPage(int p) {
    if (_page == p) return;
    setState(() => _page = p);
    final instant = MediaQuery.disableAnimationsOf(context);
    _globeKey.currentState?.spinBy(
      p == 2 ? 40 : -40,
      instant ? Duration.zero : const Duration(milliseconds: 1200),
    );
    if (p == 2) _searchFocus.unfocus();
    if (instant) {
      _pageCtl.value = p == 2 ? 1 : 0;
    } else if (p == 2) {
      _pageCtl.forward();
    } else {
      _pageCtl.reverse();
    }
  }

  /// Le bouton principal : « Continuer » (page 1), puis « Lancer la découverte ».
  void _onMain() {
    if (_page == 1) {
      HapticFeedback.selectionClick();
      _setPage(2);
      return;
    }
    HapticFeedback.mediumImpact();
    SwaycoSounds.play(SwSound.globeLaunch);
    Navigator.of(context).pop<GlobeResult>(
      (countries: _selected, gender: _gender),
    );
  }

  String get _genderSummary =>
      AppStrings.t('globe_gender_summary_${_gender.name}');

  /// Le globe de la page 2 : 370 px plus bas, échelle 0,91, opacité 0,55.
  Widget _globeAnim(double h, Widget child) {
    return AnimatedBuilder(
      animation: _globeT,
      builder: (_, c) {
        final t = _globeT.value;
        return Opacity(
          opacity: 1 - 0.45 * t,
          child: Transform.translate(
            offset: Offset(0, 370 * (h / 844) * t),
            child: Transform.scale(scale: 1 - 0.09 * t, child: c),
          ),
        );
      },
      child: child,
    );
  }

  /// Un bloc de la page 1 : fondu sortant + 14 px vers le haut, puis inerte.
  Widget _page1Fx(Widget child) {
    return AnimatedBuilder(
      animation: _p1T,
      builder: (_, c) => IgnorePointer(
        ignoring: _p1T.value > 0.5,
        child: Opacity(
          opacity: 1 - _p1T.value,
          child: Transform.translate(
            offset: Offset(0, -14 * _p1T.value),
            child: c,
          ),
        ),
      ),
      child: child,
    );
  }

  /// Un bloc de la page 2 : entre à [startMs] (450 ms), fondu + glissement.
  Widget _reveal(int startMs, Widget child, {double dy = 14}) {
    final fade = _pageCtl.drive(
      CurveTween(
        curve: Interval(startMs / 1200, (startMs + 450) / 1200,
            curve: Curves.easeOut),
      ),
    );
    final move = _pageCtl.drive(
      CurveTween(curve: Interval(startMs / 1200, (startMs + 450) / 1200,
          curve: Curves.easeOutBack)),
    );
    return AnimatedBuilder(
      animation: _pageCtl,
      builder: (_, c) => IgnorePointer(
        ignoring: _page != 2,
        child: Opacity(
          opacity: fade.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy * (1 - move.value)),
            child: c,
          ),
        ),
      ),
      child: child,
    );
  }

  /// Barre du haut de la page 2 : retour, deux barres de progression, « 2/2 ».
  Widget _page2Bar() {
    final light = SC.light;
    return Row(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _setPage(1),
          child: _Glass(
            radius: 99,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.arrow_back_rounded,
                color: light ? SC.textPrimary : Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: light
                        ? const Color(0x591F5EFF)
                        : SC.accent.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: light ? const Color(0xFF1F5EFF) : SC.accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _Glass(
          radius: 99,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: Text(
                  '2/2',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 12,
                    color: light ? SC.textPrimary : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Les trois choix, empilés (Mixte pré-sélectionné) — tout est libre.
  Widget _genderCards() {
    Widget card(GenderFilter g, IconData icon, String key) => _GenderCard(
          icon: icon,
          title: AppStrings.t('globe_gender_$key'),
          sub: AppStrings.t('globe_gender_${key}_sub'),
          selected: _gender == g,
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _gender = g);
          },
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _reveal(510, card(GenderFilter.homme, Icons.male_rounded, 'man'),
            dy: 24),
        const SizedBox(height: 12),
        _reveal(590, card(GenderFilter.femme, Icons.female_rounded, 'woman'),
            dy: 24),
        const SizedBox(height: 12),
        _reveal(670,
            card(GenderFilter.mixte, Icons.diversity_1_rounded, 'mixed'),
            dy: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final h = mq.size.height;
    final canLaunch = _selected.isNotEmpty;
    final globeSide = w * 1.8;
    final barTop = mq.padding.top + 12;
    final matches = _matches;

    return PopScope(
      canPop: _page == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page == 2) _setPage(1);
      },
      child: Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.2, 0.1),
            radius: 1.0,
            // Clair : bleu très pâle → blanc (17d). Sombre : valeurs d'avant.
            colors: SC.light
                ? const [Color(0xFFCFE0FF), Color(0xFFEAF2FF), Color(0xFFFFFFFF)]
                : const [Color(0xFF1F4FD6), Color(0xFF0F1A3A), Color(0xFF0A0F1C)],
            stops: const [0, 0.55, 1],
          ),
        ),
        child: Stack(
          children: [
            // ── Le globe, immense : il dépasse à gauche et en bas. ───────────
            Positioned.fill(
              child: _globeAnim(
                h,
                Stack(
                  clipBehavior: Clip.none,
                  children: [
            Positioned(
              left: -0.38 * w,
              top: 0.18 * h,
              width: globeSide,
              height: globeSide,
              child: _world == null
                  ? const SizedBox.shrink()
                  : Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Liseré bleu (5 px, 50 %) et halo bleu, collés au bord
                        // du disque (le globe se peint à 8 px de son cadre).
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: SC.brandBlue
                                          .withValues(alpha: SC.light ? 0.28 : 0.5),
                                      spreadRadius: 5,
                                    ),
                                    BoxShadow(
                                      color: SC.brandBlue
                                          .withValues(alpha: SC.light ? 0.16 : 0.3),
                                      blurRadius: 90,
                                      spreadRadius: 12,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        RepaintBoundary(
                          child: _GlobeView(
                            key: _globeKey,
                            world: _world!,
                            selected: _selected,
                            onToggle: _toggle,
                          ),
                        ),
                      ],
                    ),
            ),
                  ],
                ),
              ),
            ),
            if (_world == null)
              Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    color: SC.light ? SC.brandBlueDeep : Colors.white54,
                    strokeWidth: 2,
                  ),
                ),
              ),

            // Voile sombre : le globe passe au second plan sur la page 2.
            if (!SC.light)
              Positioned.fill(
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _pageCtl,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x33000000),
                            Color(0x8C000000),
                            Color(0x00000000),
                          ],
                          stops: [0, 0.5, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // ── Titre : « Où veux-tu [voyager ?] ». ─────────────────────────
            Positioned(
              top: barTop + 44 + 18,
              left: 20,
              child: _page1Fx(
                IgnorePointer(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: _title(),
                  ),
                ),
              ),
            ),

            // ── Barre du haut : fermer + recherche, en verre. ────────────────
            Positioned(
              top: barTop,
              left: 14,
              right: 14,
              child: _page1Fx(Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(),
                    child: _Glass(
                      radius: 99,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.close_rounded,
                          color: SC.light ? SC.textPrimary : Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Glass(
                      radius: 99,
                      child: SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            const SizedBox(width: 14),
                            Icon(
                              Icons.search_rounded,
                              size: 20,
                              color: SC.light ? SC.textMuted : Colors.white.withValues(alpha: 0.65),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _search,
                                focusNode: _searchFocus,
                                textInputAction: TextInputAction.search,
                                cursorColor: SC.accentFg,
                                style: GoogleFonts.dmSans(
                                  fontSize: 14,
                                  color: SC.light ? SC.textPrimary : Colors.white,
                                ),
                                decoration: InputDecoration(
                                  isCollapsed: true,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  hintText: AppStrings.t('globe_search_hint'),
                                  hintStyle: GoogleFonts.dmSans(
                                    fontSize: 14,
                                    color: SC.light
                                        ? SC.textMuted
                                        : Colors.white.withValues(alpha: 0.65),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              )),
            ),

            // ── Résultats de la recherche. ────────────────────────────────────
            if (matches.isNotEmpty && _page == 1)
              Positioned(
                top: barTop + 44 + 8,
                left: 14 + 44 + 10,
                right: 14,
                child: _Glass(
                  radius: 22,
                  tint: 0.55,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final key in matches)
                        InkWell(
                          onTap: () => _pickFromSearch(key),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                _GlobeFlag(
                                  code: kGlobeCountries[key]!.code,
                                  emoji: kGlobeCountries[key]!.flag,
                                  height: 16,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _nameOf(key),
                                    style: GoogleFonts.dmSans(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: SC.light ? SC.textPrimary : Colors.white,
                                    ),
                                  ),
                                ),
                                if (_selected.contains(key))
                                  Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: SC.accentFg,
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            // ── Page 2 : « Qui veux-tu y rencontrer ? ». ─────────────────────
            Positioned(
              top: barTop,
              left: 14,
              right: 14,
              child: _reveal(350, _page2Bar()),
            ),
            Positioned(
              top: barTop + 56,
              left: 20,
              child: _reveal(
                430,
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: _title(key: 'globe_gender_title', spacing: -1.2),
                ),
              ),
            ),
            Positioned(
              top: barTop + 190,
              left: 14,
              right: 14,
              child: _genderCards(),
            ),

            // ── Barre du bas : puces des pays choisis + valider. ─────────────
            Positioned(
              left: 14,
              right: 14,
              bottom: mq.padding.bottom + 12,
              child: _Glass(
                radius: 30,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
                        child: Row(
                          children: [
                            for (final key in _selected) ...[
                              _CountryChip(
                                code: kGlobeCountries[key]!.code,
                                emoji: kGlobeCountries[key]!.flag,
                                name: _nameOf(key),
                                onTap: () => _toggle(key),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              _page == 1
                                  ? AppStrings.t('globe_pinch')
                                  : _genderSummary,
                              maxLines: 1,
                              style: GoogleFonts.dmSans(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: SC.light ? SC.textSecondary : Colors.white.withValues(alpha: 0.75),
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: canLaunch ? _onMain : null,
                        child: Container(
                          height: 54,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: canLaunch
                                ? SC.accent
                                : (SC.light
                                    ? const Color(0x1F1F5EFF)
                                    : Colors.white.withValues(alpha: 0.14)),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            canLaunch
                                ? AppStrings.t(
                                    _page == 1 ? 'globe_next' : 'globe_launch_go',
                                  )
                                : AppStrings.t('globe_pick_one'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: popupDisplay(
                              fontSize: 15,
                              color: canLaunch
                                  ? SC.onAccent
                                  : (SC.light
                                      ? SC.textMuted
                                      : Colors.white.withValues(alpha: 0.55)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// « Où veux-tu [voyager ?] » : le `|` de la traduction marque le début du
  /// groupe posé sur la pastille jaune (il ne se coupe pas).
  Widget _title({String key = 'globe_title_v2', double spacing = -0.6}) {
    final style = popupDisplay(
      fontSize: 30,
      height: 1.1,
      letterSpacing: spacing,
      color: SC.light ? const Color(0xFF04123A) : Colors.white,
    ).copyWith(
      // Clair : pas d'ombre sous le titre.
      shadows: SC.light
          ? const []
          : const [Shadow(color: Color(0x66000000), blurRadius: 12)],
    );
    final raw = AppStrings.t(key);
    final cut = raw.indexOf('|');
    if (cut < 0) return Text(raw, style: style);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: raw.substring(0, cut)),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: SC.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                raw.substring(cut + 1),
                maxLines: 1,
                softWrap: false,
                style: style.copyWith(color: SC.onAccent, shadows: const []),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Une carte de choix de la page 2 : icône, titre, sous-titre, coche.
class _GenderCard extends StatelessWidget {
  const _GenderCard({
    required this.icon,
    required this.title,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final ink = light ? const Color(0xFF04123A) : Colors.white;
    final border = selected
        ? (light ? const Color(0xFF1F5EFF) : SC.accent)
        : (light ? const Color(0x381F5EFF) : const Color(0x38FFFFFF));
    final fill = selected
        ? (light ? const Color(0x141F5EFF) : const Color(0x24F4FF1F))
        : (light ? Colors.white : Colors.white.withValues(alpha: 0.10));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 88,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: border, width: selected ? 2 : 1.2),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: selected ? SC.brandGradient : null,
                    color: selected
                        ? null
                        : (light
                            ? const Color(0x1A1F5EFF)
                            : const Color(0x24FFFFFF)),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    icon,
                    size: 30,
                    color: selected || !light
                        ? Colors.white
                        : const Color(0xFF1F5EFF),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: popupDisplay(fontSize: 19, color: ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: ink.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? SC.accent : Colors.transparent,
                    border: selected
                        ? null
                        : Border.all(
                            color: light
                                ? const Color(0x661F5EFF)
                                : Colors.white.withValues(alpha: 0.4),
                            width: 2,
                          ),
                  ),
                  child: selected
                      ? const Icon(
                          Icons.check_rounded,
                          size: 19,
                          color: SC.onAccent,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le verre de la barre de navigation : blanc 13 %, bord blanc 22 % de 1,2 px,
/// flou 28. [tint] > 0.13 fonce le fond (liste de résultats, plus lisible).
class _Glass extends StatelessWidget {
  const _Glass({required this.child, required this.radius, this.tint = 0.13});

  final Widget child;
  final double radius;
  final double tint;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: SC.light
                ? (tint > 0.13
                    ? const Color(0xE6FFFFFF)
                    : const Color(0x141F5EFF))
                : (tint > 0.13
                    ? SC.onAccent.withValues(alpha: tint)
                    : Colors.white.withValues(alpha: tint)),
            borderRadius: r,
            border: Border.all(
              color: SC.light
                  ? const Color(0x331F5EFF)
                  : Colors.white.withValues(alpha: 0.22),
              width: 1.2,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Vrai drapeau (flagcdn), l'emoji du pays à défaut.
class _GlobeFlag extends StatelessWidget {
  const _GlobeFlag({
    required this.code,
    required this.emoji,
    required this.height,
  });

  final String code;
  final String emoji;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Image.network(
        'https://flagcdn.com/w80/${code.toLowerCase()}.png',
        height: height,
        errorBuilder: (_, _, _) => Text(
          emoji,
          style: TextStyle(fontSize: height, height: 1),
        ),
      ),
    );
  }
}

/// Une puce de pays choisi : un tap la retire.
class _CountryChip extends StatelessWidget {
  const _CountryChip({
    required this.code,
    required this.emoji,
    required this.name,
    required this.onTap,
  });

  final String code;
  final String emoji;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Toute la puce est une cible de retrait ; le ✕ jaune en haut à droite
    // en est une zone élargie (44 × 44, DANS les bornes du widget : ce qui
    // dépasse d'un Stack ne reçoit aucun tap — c'est ce qui obligeait à
    // taper plusieurs fois).
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 50,
        child: Stack(
          alignment: Alignment.bottomLeft,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Container(
                height: 34,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                decoration: BoxDecoration(
                  color: SC.light
                      ? const Color(0x1F1F5EFF)
                      : SC.onAccent.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _GlobeFlag(code: code, emoji: emoji, height: 13),
                    const SizedBox(width: 7),
                    Text(
                      name,
                      maxLines: 1,
                      softWrap: false,
                      style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: SC.light ? SC.textPrimary : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Align(
                    alignment: Alignment.topRight,
                    // Posé SUR le coin haut-droit de la puce (et non au-dessus).
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3, right: 6),
                      child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: SC.light ? SC.brandBlueDeep : SC.onAccent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: SC.light ? Colors.white : SC.accent,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        color: SC.light ? Colors.white : SC.accent,
                        size: 12,
                      ),
                    ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── The interactive globe ───────────────────────────────────────────────────

class _GlobeView extends StatefulWidget {
  const _GlobeView({
    super.key,
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
  late final AnimationController _byCtrl;
  double _byFrom = 0, _byDelta = 0;
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
    _byCtrl = AnimationController(vsync: this)..addListener(_onBy);
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
    _byCtrl.dispose();
    super.dispose();
  }

  void _onSpin(Duration _) {
    if (_dragging || _flying || _byCtrl.isAnimating) return;
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

  void _onBy() {
    final t = Curves.easeInOutCubic.transform(_byCtrl.value);
    setState(() => _rotLon = _byFrom + _byDelta * t);
  }

  /// Fait tourner le globe de [deg] degrés en [duration] (transition de page),
  /// sans casser la rotation automatique ni le vol vers un pays.
  void spinBy(double deg, Duration duration) {
    _velLon = _velLat = 0;
    if (duration == Duration.zero) {
      setState(() => _rotLon += deg);
      return;
    }
    _byFrom = _rotLon;
    _byDelta = deg;
    _byCtrl.duration = duration;
    _byCtrl.forward(from: 0);
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

  /// Amène le globe sur un pays (résultat de la recherche).
  void flyToCountry(String key) {
    final c = kGlobeCountries[key]?.center;
    if (c != null) _flyTo(c);
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
              // Sensibilité d'origine (0.25), très légèrement relevée.
              final k = 0.28 / _scale;
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
            ..strokeWidth = 1.4
            ..color = SC.brandBlue.withValues(alpha: 0.9),
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

    // ── White label bubbles (FR / DE / CA / JP / BE / BR) — outside the
    //    clip so they can float over the rim, like the prototype's pins. ──
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
          ..color = picked
              ? (SC.light ? SC.brandBlueDeep : SC.accent)
              : const Color(0xFFC9C2B2),
      );
      // Country code.
      final tp = TextPainter(
        text: TextSpan(
          text: kGlobeCountries[key]!.code.toUpperCase(),
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
