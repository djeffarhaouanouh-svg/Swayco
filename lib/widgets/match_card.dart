// swaycø — MatchCard (variants 4a "first" + plain "standard").
//
// Selection rule:
//   first accepted match       -> MatchCardKind.first
//   otherwise                  -> MatchCardKind.standard
//
// Flag colours are only ever used for the round photo ring of `first`.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/profile_api.dart';
import 'flag_gradients.dart';
import 'profile_avatar.dart';

enum MatchCardKind { first, standard }

const _cyan = Color(0xFF22D3EE);
const _cyanInk = Color(0xFF04262D);

class MatchCard extends StatefulWidget {
  const MatchCard({
    super.key,
    required this.kind,
    required this.peer,
    required this.onSayHi,
    required this.onDismiss,
  });

  final MatchCardKind kind;
  final RemoteProfile peer;
  final VoidCallback onSayHi;
  final VoidCallback onDismiss;

  @override
  State<MatchCard> createState() => _MatchCardState();
}

class _MatchCardState extends State<MatchCard> with TickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..forward();

  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  )..repeat(reverse: true);

  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  /// One-shot confetti burst — fires with the card, never loops.
  late final AnimationController _confetti = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();

  @override
  void dispose() {
    _pop.dispose();
    _breath.dispose();
    _glow.dispose();
    _confetti.dispose();
    super.dispose();
  }

  late final List<_ConfettiPiece> _confettiPieces = _buildConfetti();

  RemoteProfile get _peer => widget.peer;

  bool get _isFirst => widget.kind == MatchCardKind.first;

  String get _name {
    final n = _peer.displayName.trim();
    return n.isEmpty ? AppStrings.t('profile_anonymous') : n;
  }

  /// Profile picture first — the PDP is what the mock shows.
  String get _photoUrl {
    if (_peer.avatarUrl.trim().isNotEmpty) return _peer.avatarUrl.trim();
    if (_peer.discoverPhotoUrl.trim().isNotEmpty) {
      return _peer.discoverPhotoUrl.trim();
    }
    if (_peer.photos.isNotEmpty && _peer.photos.first.trim().isNotEmpty) {
      return _peer.photos.first.trim();
    }
    return '';
  }

  /// "Alice, 24 ans, Paris"
  String get _who {
    final age = _peer.age;
    final city = _peer.city.trim();
    return [
      _name,
      if (age != null) AppStrings.t('match_age_years', args: {'n': '$age'}),
      if (city.isNotEmpty) city,
    ].join(', ');
  }

  String get _translationNote =>
      AppStrings.t('match_tip_auto_translate', args: {'name': _name});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.64),
          radius: 1.1,
          colors: [Color(0xFF123C46), Color(0xFF05070A)],
          stops: [0, 0.6],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          _halo(),
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
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Center(
                child: ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _pop,
                    curve: Curves.easeOutBack,
                  ),
                  child: FadeTransition(
                    opacity: _pop,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: SingleChildScrollView(
                        child: _roundBody(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _halo() => Positioned(
        top: 80,
        child: AnimatedBuilder(
          animation: _breath,
          builder: (_, _) {
            final t = _breath.value;
            return Transform.scale(
              scale: 1 + 0.12 * t,
              child: Opacity(
                opacity: 0.55 + 0.35 * t,
                child: Container(
                  width: 440,
                  height: 440,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        _cyan.withValues(alpha: 0.4),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.66],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );

  Widget _roundBody() {
    final ring = flagRingColors(
      country: _peer.country,
      language: _peer.language,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isFirst) ...[
          _pill(
            AppStrings.t('match_pill_first').toUpperCase(),
            bg: _cyan,
            fg: _cyanInk,
          ),
          const SizedBox(height: 22),
        ],
        Container(
          width: 150,
          height: 150,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [ring.first, const Color(0xFFF2F2F4), ring.last],
            ),
          ),
          child: ClipOval(child: _photo()),
        ),
        const SizedBox(height: 22),
        Text(
          AppStrings.t(
            _isFirst ? 'match_first_title' : 'match_standard_title',
          ),
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 40,
            height: 1.05,
            letterSpacing: -1.6,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _isFirst
              ? AppStrings.t('match_first_sub', args: {'who': _who})
              : AppStrings.t('match_standard_sub', args: {'who': _who}),
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 16,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
        // The translation tile only belongs on the very first match — that's
        // the one time the user has never seen it work.
        if (_isFirst) ...[
          const SizedBox(height: 22),
          _translationTile(),
        ],
        const SizedBox(height: 22),
        _primaryButton(),
        const SizedBox(height: 11),
        _dismissLink(),
      ],
    );
  }

  Widget _photo() {
    final url = _photoUrl;
    final fallback = ColoredBox(
      color: const Color(0xFF111111),
      child: Center(child: ProfileAvatar(displayName: _name, size: 96)),
    );
    if (url.isEmpty) return fallback;
    return Image.network(
      url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => fallback,
    );
  }

  Widget _pill(
    String text, {
    required Color bg,
    required Color fg,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          style: GoogleFonts.interTight(
            fontSize: 11,
            height: 1,
            letterSpacing: 1.32,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      );

  Widget _translationTile() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _cyan.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('🗣️', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _translationNote,
                style: GoogleFonts.interTight(
                  fontSize: 12.5,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _primaryButton() => AnimatedBuilder(
        animation: _glow,
        builder: (_, _) {
          final t = _glow.value;
          return GestureDetector(
            onTap: widget.onSayHi,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _cyan,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: _cyan.withValues(alpha: 0.5 * (1 - t)),
                    blurRadius: 0,
                    spreadRadius: 14 * t,
                  ),
                  BoxShadow(
                    color: _cyan.withValues(alpha: 0.35 + 0.15 * t),
                    blurRadius: 40,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Text(
                AppStrings.t('match_say_hi'),
                style: GoogleFonts.interTight(
                  fontSize: 16.5,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: _cyanInk,
                ),
              ),
            ),
          );
        },
      );

  Widget _dismissLink() => GestureDetector(
        onTap: widget.onDismiss,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            AppStrings.t('match_later'),
            style: GoogleFonts.interTight(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.42),
            ),
          ),
        ),
      );
}

MatchCardKind resolveMatchCardKind({required int acceptedMatchCount}) {
  if (acceptedMatchCount <= 1) return MatchCardKind.first;
  return MatchCardKind.standard;
}

// ── confetti ────────────────────────────────────────────────────────────────

/// One paper rectangle: where it starts, how it flies, how it tumbles.
class _ConfettiPiece {
  const _ConfettiPiece({
    required this.startX,
    required this.angle,
    required this.speed,
    required this.spin,
    required this.width,
    required this.height,
    required this.color,
    required this.delay,
    required this.drift,
  });

  /// Horizontal launch point, 0..1 of the card width.
  final double startX;
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
    _cyan,
    Color(0xFFA78BFA),
    Color(0xFFF472B6),
    Color(0xFFFBBF24),
    Color(0xFF34D399),
  ];
  return [
    for (var i = 0; i < 46; i++)
      _ConfettiPiece(
        startX: rng.nextDouble(),
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

/// Confetti that erupts from behind the photo, then falls and fades.
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
