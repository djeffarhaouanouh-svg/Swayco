// swaycø — MatchCard, direction 8c, variante 4b « Deux villes, un trajet ».
//
// Deux photos (toi à gauche, le match à droite) reliées par un arc en
// pointillés, une pastille « ✈ {km} km » à son sommet, et le titre « Bravo !
// Ton voyage {au} commence. » dont le pays est posé sur une pastille jaune.
//
// Pays inconnu / vide : même décor, titre générique `match_standard_title`,
// ni arc ni distance.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/locations.dart';
import '../services/match_country.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';
import 'profile_avatar.dart';

enum MatchCardKind { first, standard }

/// Photo ronde : 132 de diamètre, bordure de 4.
const double _photoSize = 132;
const double _photoBorder = 4;

/// La zone « voyage » (arc + photos + pastille).
const double _travelW = 300;
const double _travelH = 200;

/// Bleu nuit des ombres (maquette : 2,12,60).
const Color _shadowBlue = Color(0xFF020C3C);

class MatchCard extends StatefulWidget {
  const MatchCard({
    super.key,
    required this.kind,
    required this.peer,
    required this.onSayHi,
    required this.onDismiss,
    this.me,
  });

  final MatchCardKind kind;
  final RemoteProfile peer;

  /// Moi : la photo et la ville de gauche. Absent → le côté gauche reste vide.
  final RemoteProfile? me;
  final VoidCallback onSayHi;
  final VoidCallback onDismiss;

  @override
  State<MatchCard> createState() => _MatchCardState();
}

class _MatchCardState extends State<MatchCard> with TickerProviderStateMixin {
  /// Les photos arrivent de 60 px plus bas / plus haut (700 ms).
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();

  /// La pastille de distance pop (500 ms) — dès que la distance est connue.
  late final AnimationController _pill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  /// Un seul jet de confettis, jamais de boucle.
  late final AnimationController _confetti = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();

  late final List<_ConfettiPiece> _confettiPieces = _buildConfetti();

  late final MatchCountry? _country = matchCountryFor(widget.peer);
  double? _km;

  @override
  void initState() {
    super.initState();
    if (_country != null) _loadDistance();
  }

  @override
  void dispose() {
    _slide.dispose();
    _pill.dispose();
    _glow.dispose();
    _confetti.dispose();
    super.dispose();
  }

  /// Ta ville → la sienne, par l'API de géocodage. Pas de coordonnées :
  /// la pastille reste masquée.
  Future<void> _loadDistance() async {
    final me = widget.me;
    if (me == null) return;
    final coords = await Future.wait([
      CityGeo.coordsFor(city: me.city, country: me.country),
      CityGeo.coordsFor(city: widget.peer.city, country: widget.peer.country),
    ]);
    final a = coords[0], b = coords[1];
    if (a == null || b == null || !mounted) return;
    setState(() => _km = CityGeo.distanceKm(a, b));
    _pill.forward();
  }

  String get _name {
    final n = widget.peer.displayName.trim();
    return n.isEmpty ? AppStrings.t('profile_anonymous') : n;
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final small = MediaQuery.sizeOf(context).height < 700;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          // 160° : vers le bas, un peu vers la droite.
          begin: Alignment(-0.34, -0.94),
          end: Alignment(0.34, 0.94),
          colors: [SC.brandBlueDeep, SC.brandBlue, SC.brandCyan],
          stops: [0, 0.52, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _confetti,
                builder: (_, _) => CustomPaint(
                  painter: _ConfettiPainter(
                    progress: _confetti.value,
                    pieces: _confettiPieces,
                  ),
                ),
              ),
            ),
          ),
          // Le contenu défile s'il ne tient pas (petit écran, gros texte) ;
          // le bas est réservé au bouton.
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                safe.top + (small ? 40 : 110),
                24,
                safe.bottom + 56 + 6 + 44 + 34,
              ),
              child: Column(
                children: [
                  _travel(),
                  const SizedBox(height: 56),
                  _title(),
                ],
              ),
            ),
          ),
          Positioned(
            left: 22,
            right: 22,
            bottom: safe.bottom + 14,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _primaryButton(),
                const SizedBox(height: 6),
                _dismissLink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Zone voyage ────────────────────────────────────────────────────────────

  Widget _travel() {
    final showArc = _country != null;
    return SizedBox(
      width: _travelW,
      height: _travelH,
      child: AnimatedBuilder(
        animation: Listenable.merge([_slide, _pill]),
        builder: (_, _) {
          final s = Curves.easeOutCubic.transform(_slide.value);
          // Toi : monte de 60 px ; le match : descend de 60 px.
          final leftY = 60 + 60 * (1 - s);
          final rightY = 60 - 60 * (1 - s);
          final km = _km;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (showArc)
                const Positioned.fill(
                  child: CustomPaint(painter: _ArcPainter()),
                ),
              Positioned(
                left: 0,
                top: leftY,
                child: _person(widget.me, borderColor: Colors.white),
              ),
              Positioned(
                right: 0,
                top: rightY,
                child: _person(widget.peer, borderColor: SC.accent),
              ),
              if (showArc && km != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 10,
                  child: Center(
                    child: Transform.scale(
                      scale: Curves.easeOutBack.transform(_pill.value),
                      child: _kmPill(km),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Photo ronde + drapeau et ville dessous.
  Widget _person(RemoteProfile? p, {required Color borderColor}) {
    if (p == null) return const SizedBox(width: _photoSize);
    final name = p.displayName.trim();
    final city = p.city.trim();
    final iso = countryIso2For(p.country);
    return SizedBox(
      width: _photoSize,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _photoSize,
            height: _photoSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: borderColor, width: _photoBorder),
              boxShadow: [
                BoxShadow(
                  color: _shadowBlue.withValues(alpha: 0.6),
                  blurRadius: 40,
                  spreadRadius: -10,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            // Photo de profil, avec repli sur la photo de découverte / la
            // première photo, puis sur l'initiale colorée.
            child: ClipOval(
              child: ProfileAvatar(
                displayName: name,
                avatarUrl: p.avatarUrl,
                fallbackUrl: p.fallbackPhotoUrl,
                size: _photoSize - _photoBorder * 2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (city.isNotEmpty || iso.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (iso.isNotEmpty) ...[
                  _FlagImage(code: iso, countryName: p.country),
                  if (city.isNotEmpty) const SizedBox(width: 6),
                ],
                if (city.isNotEmpty)
                  Flexible(
                    child: Text(
                      city,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _kmPill(double km) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: SC.onAccent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '✈ ${_formatKm(km)} km',
          maxLines: 1,
          softWrap: false,
          style: GoogleFonts.dmSans(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: SC.accent,
          ),
        ),
      );

  /// 9600 → « 9 600 ».
  static String _formatKm(double km) {
    final s = km.round().toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(' ');
      out.write(s[i]);
    }
    return out.toString();
  }

  // ── Titre ──────────────────────────────────────────────────────────────────

  /// « Bravo ! Ton voyage [au Japon] commence. » — la phrase entière vient de
  /// la traduction ; seul le groupe `{au}` est repéré pour porter la pastille.
  Widget _title() {
    final style = popupDisplay(
      fontSize: 30,
      height: 1.15,
      letterSpacing: -0.6,
      color: Colors.white,
    );
    final country = _country;
    if (country == null) {
      return Text(
        AppStrings.t('match_standard_title'),
        textAlign: TextAlign.center,
        style: style,
      );
    }
    const mark = '\u0001';
    final parts =
        AppStrings.t('match_voyage_title', args: {'au': mark}).split(mark);
    final before = parts.first;
    final after = parts.length > 1 ? parts.sublist(1).join(mark) : '';
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: before),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: SC.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                country.au,
                maxLines: 1,
                softWrap: false,
                style: style.copyWith(color: SC.onAccent),
              ),
            ),
          ),
          TextSpan(text: after),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  // ── Boutons ────────────────────────────────────────────────────────────────

  Widget _primaryButton() => AnimatedBuilder(
        animation: _glow,
        builder: (_, _) {
          final t = _glow.value;
          return GestureDetector(
            onTap: widget.onSayHi,
            child: Container(
              width: double.infinity,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: SC.accent,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  // Halo jaune qui respire.
                  BoxShadow(
                    color: SC.accent.withValues(alpha: 0.45 * (1 - t)),
                    blurRadius: 0,
                    spreadRadius: 12 * t,
                  ),
                  BoxShadow(
                    color: _shadowBlue.withValues(alpha: 0.3),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Text(
                AppStrings.t('match_cta_write', args: {'peer': _name}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: popupDisplay(fontSize: 15, color: SC.onAccent),
              ),
            ),
          );
        },
      );

  Widget _dismissLink() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onDismiss,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              AppStrings.t('match_later'),
              style: GoogleFonts.dmSans(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
      );
}

MatchCardKind resolveMatchCardKind({required int acceptedMatchCount}) {
  if (acceptedMatchCount <= 1) return MatchCardKind.first;
  return MatchCardKind.standard;
}

// ── Drapeau ──────────────────────────────────────────────────────────────────

/// Vrai drapeau (hauteur 12, coins 2) depuis flagcdn ; à défaut, l'emoji du
/// pays — les croix nordiques ou l'Union Jack ne se bricolent pas en bandes.
class _FlagImage extends StatelessWidget {
  const _FlagImage({required this.code, required this.countryName});

  final String code;
  final String countryName;

  @override
  Widget build(BuildContext context) {
    final emoji = countryFlagFor(countryName);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Image.network(
        'https://flagcdn.com/w80/${code.toLowerCase()}.png',
        height: 12,
        errorBuilder: (_, _, _) => emoji == null
            ? const SizedBox(height: 12)
            : Text(emoji, style: const TextStyle(fontSize: 12, height: 1)),
      ),
    );
  }
}

// ── Arc ──────────────────────────────────────────────────────────────────────

/// Arc en pointillés jaunes (3 px, 8 / 8) : de (70,130) à (230,130), sommet
/// en haut — dessiné dans le repère 300 × 200 de la maquette.
class _ArcPainter extends CustomPainter {
  const _ArcPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / _travelW, size.height / _travelH);
    final path = Path()
      ..moveTo(70, 130)
      ..quadraticBezierTo(150, 10, 230, 130);
    final paint = Paint()
      ..color = SC.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 8, metric.length)),
          paint,
        );
        d += 16;
      }
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) => false;
}

// ── Confettis ────────────────────────────────────────────────────────────────

/// One paper rectangle: where it starts, how it flies, how it tumbles.
class _ConfettiPiece {
  const _ConfettiPiece({
    required this.angle,
    required this.speed,
    required this.spin,
    required this.width,
    required this.height,
    required this.color,
    required this.delay,
    required this.drift,
  });

  final double angle;
  final double speed;
  final double spin;
  final double width;
  final double height;
  final Color color;

  /// 0..1 of the animation spent waiting before this piece launches.
  final double delay;
  final double drift;
}

List<_ConfettiPiece> _buildConfetti() {
  // Fixed seed: the burst is identical on every rebuild of the same card,
  // so a resize or a rebuild doesn't reshuffle mid-flight.
  final rng = math.Random(42);
  const palette = [
    SC.accent,
    SC.brandCyan,
    Colors.white,
    SC.brandBlue,
    SC.accent,
  ];
  return [
    for (var i = 0; i < 34; i++)
      _ConfettiPiece(
        angle: rng.nextDouble() * math.pi * 2,
        speed: 0.75 + rng.nextDouble() * 0.75,
        spin: (rng.nextDouble() * 2 - 1) * 7,
        width: 5 + rng.nextDouble() * 5,
        height: 9 + rng.nextDouble() * 7,
        color: palette[rng.nextInt(palette.length)],
        delay: rng.nextDouble() * 0.22,
        drift: (rng.nextDouble() * 2 - 1) * 0.32,
      ),
  ];
}

/// Confetti that erupts from the top of the travel zone, then falls and fades.
class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({required this.progress, required this.pieces});

  final double progress;
  final List<_ConfettiPiece> pieces;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final origin = Offset(size.width / 2, size.height * 0.30);
    final paint = Paint();

    for (final p in pieces) {
      final t = ((progress - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (t <= 0) continue;

      // Burst outward, then gravity takes over — the classic pop-and-fall.
      final burst = (1 - math.pow(1 - t, 3).toDouble()) * p.speed;
      final spread = size.width * 0.62 * burst;
      final dx = math.cos(p.angle) * spread + p.drift * size.width * t;
      final dy = math.sin(p.angle) * spread * 0.55 +
          size.height * 0.95 * t * t * p.speed;

      final centre = origin + Offset(dx, dy);
      if (centre.dy > size.height + 40) continue;

      // Hold full opacity through the burst, fade only on the way out.
      final opacity = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
      paint.color = p.color.withValues(alpha: opacity);

      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(p.angle + p.spin * t);
      // Tumbling: the rectangle squashes as it turns edge-on to the viewer.
      final squash = math.cos(t * p.spin * 1.6).abs().clamp(0.25, 1.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: p.width,
            height: p.height * squash,
          ),
          const Radius.circular(1.5),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}
