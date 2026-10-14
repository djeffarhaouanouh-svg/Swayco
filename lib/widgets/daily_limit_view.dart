import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../screens/paywall_screen.dart';
import '../services/app_strings.dart';
import '../services/daily_swipes.dart';
import '../theme/swayco_theme.dart';
import 'discover_globe.dart' show kGlobeCountries;
import 'popup_kit.dart' show popupDisplay;

/// Un profil récemment vu : sa photo (floutée) et son pays (drapeau).
typedef SeenProfile = ({String? photoUrl, String country});

/// Fin du swipe journalier, compte gratuit : trois cartes floutées, compteur,
/// minuteur jusqu'à minuit et bouton Pro. Remplace la zone des cartes.
class DailyLimitView extends StatefulWidget {
  const DailyLimitView({
    super.key,
    required this.seen,
    required this.onReset,
  });

  /// Jusqu'à trois profils vus (les plus récents).
  final List<SeenProfile> seen;

  /// Minuit passé : le compteur est remis à zéro, Discover reprend.
  final VoidCallback onReset;

  @override
  State<DailyLimitView> createState() => _DailyLimitViewState();
}

class _DailyLimitViewState extends State<DailyLimitView> {
  Timer? _tick;
  late Duration _left = _remaining();

  Duration _remaining() {
    final d = DailySwipes.nextReset().difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      final left = _remaining();
      if (left == Duration.zero) {
        _tick?.cancel();
        await DailySwipes.reset();
        if (mounted) widget.onReset();
        return;
      }
      if (mounted) setState(() => _left = left);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String get _clock {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(_left.inHours)}:${two(_left.inMinutes % 60)}:'
        '${two(_left.inSeconds % 60)}';
  }

  String? _flagCode(String country) {
    for (final c in kGlobeCountries.values) {
      if (c.dbName.toLowerCase() == country.trim().toLowerCase()) {
        return c.code;
      }
    }
    return null;
  }

  Widget _card(int i, {required double angle, required double lift}) {
    final p = i < widget.seen.length ? widget.seen[i] : null;
    final flag = p == null ? null : _flagCode(p.country);
    return Transform.translate(
      offset: Offset(0, -lift),
      child: Transform.rotate(
        angle: angle * math.pi / 180,
        child: Container(
          width: 150,
          height: 200,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x8004123A),
                blurRadius: 30,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24.5),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (p?.photoUrl != null && p!.photoUrl!.isNotEmpty)
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Image.network(
                      p.photoUrl!,
                      fit: BoxFit.cover,
                      cacheWidth: 300,
                      errorBuilder: (_, _, _) => const _Stripes(),
                    ),
                  )
                else
                  const _Stripes(),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(0, 0),
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xBF04123A)],
                    ),
                  ),
                ),
                if (flag != null)
                  Positioned(
                    left: 10,
                    top: 10,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        width: 40,
                        height: 27,
                        child: Image.network(
                          'https://flagcdn.com/w80/$flag.png',
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = DailySwipes.freeLimit;
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.52),
                    radius: 0.7,
                    colors: [
                      SC.brandBlue.withValues(alpha: 0.6),
                      SC.brandCyan.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 300,
                    height: 230,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 0,
                          top: 28,
                          child: _card(1, angle: -14, lift: 0),
                        ),
                        Positioned(
                          right: 0,
                          top: 28,
                          child: _card(2, angle: 14, lift: 0),
                        ),
                        Positioned(
                          top: 0,
                          child: _card(0, angle: 0, lift: 0),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: Container(
                        width: 164,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.bolt_rounded,
                              size: 20,
                              color: SC.accent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              AppStrings.t(
                                'limit_counter',
                                args: {'n': '$n', 'max': '$n'},
                              ),
                              style: popupDisplay(
                                fontSize: 15,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Text(
                      AppStrings.t('limit_title'),
                      textAlign: TextAlign.center,
                      style: popupDisplay(
                        fontSize: 25,
                        letterSpacing: -1,
                        height: 1.12,
                        color: SC.fg,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (r) => LinearGradient(
                      colors: [SC.fg, SC.brandCyan],
                    ).createShader(r),
                    child: Text(
                      _clock,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 40,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.t('limit_timer_sub', args: {'n': '$n'}),
                    textAlign: TextAlign.center,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13.5,
                      color: SC.fgA(0.72),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showPaywallSheet(context),
                      child: Container(
                        height: 58,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: SC.accent,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: SC.accent.withValues(alpha: 0.65),
                              blurRadius: 34,
                              offset: const Offset(0, 14),
                            ),
                            BoxShadow(
                              color: SC.accent.withValues(alpha: 0.18),
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.all_inclusive_rounded,
                              size: 22,
                              color: SC.onAccent,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                AppStrings.t('limit_cta'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: popupDisplay(
                                  fontSize: 14,
                                  color: SC.onAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Repli sans photo : deux rayures bleu nuit.
class _Stripes extends StatelessWidget {
  const _Stripes();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _StripesPainter());
}

class _StripesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const a = Color(0xFF2F3A66);
    const b = Color(0xFF283258);
    canvas.drawRect(Offset.zero & size, Paint()..color = a);
    final p = Paint()..color = b;
    for (double x = -size.height; x < size.width; x += 28) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + 14, size.height)
        ..lineTo(x + 14 + size.height, 0)
        ..lineTo(x + size.height, 0)
        ..close();
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
