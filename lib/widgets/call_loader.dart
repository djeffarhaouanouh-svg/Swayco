import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// L'écran qui précède l'appel (loader « A · 8c ») : fond dégradé de marque,
/// logo immobile au centre, trois ondes qui respirent autour, et le conseil
/// dans une carte de verre. Un seul rendu, identique en clair et en sombre.
class CallLoader extends StatefulWidget {
  const CallLoader({super.key, required this.logo});

  /// Le logo (déjà préchauffé au boot par l'appelant).
  final ImageProvider logo;

  @override
  State<CallLoader> createState() => _CallLoaderState();
}

class _CallLoaderState extends State<CallLoader>
    with SingleTickerProviderStateMixin {
  static const _yellow = Color(0xFFF4FF1F);

  late final AnimationController _waves = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _waves.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-0.6, -1),
              end: Alignment(0.6, 1),
              colors: [Color(0xFF1F5EFF), Color(0xFF2B7FFF), Color(0xFF18DDEA)],
              stops: [0, 0.52, 1],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                Align(
                  alignment: const Alignment(0, -0.22),
                  child: SizedBox(
                    width: 460,
                    height: 460,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        for (var i = 0; i < 3; i++) _wave(i),
                        DecoratedBox(
                          decoration: const BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x66020C3C),
                                blurRadius: 22,
                                offset: Offset(0, 14),
                              ),
                            ],
                          ),
                          child: Image(
                            image: widget.logo,
                            width: 278,
                            height: 278,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 48),
                    child: _tipCard(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Diamètres 220 / 320 / 420, opacités 38 / 24 / 14 %, phases décalées d'un
  /// tiers de cycle : chaque onde grossit (0,92 → 1,12) et s'éteint.
  Widget _wave(int i) {
    const sizes = [220.0, 320.0, 420.0];
    const alphas = [0.38, 0.24, 0.14];
    return AnimatedBuilder(
      animation: _waves,
      builder: (_, _) {
        final t = (_waves.value + i / 3) % 1.0;
        final e = Curves.easeOut.transform(t);
        final scale = 0.92 + 0.20 * e;
        return Opacity(
          opacity: (1 - e).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: sizes[i],
              height: sizes[i],
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: alphas[i]),
                  width: 1.5,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tipCard() {
    final main = AppStrings.t('call_tip_1_main');
    final key = AppStrings.t('call_tip_1_key');
    final sub = AppStrings.t('call_tip_1_sub');
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 322),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.30),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: _yellow,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.mic_rounded,
                  size: 20,
                  color: SC.onAccent,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '$main '),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 7),
                              decoration: BoxDecoration(
                                color: _yellow,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                key,
                                softWrap: false,
                                style: _titleStyle(SC.onAccent),
                              ),
                            ),
                          ),
                        ],
                      ),
                      style: _titleStyle(Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle _titleStyle(Color c) => GoogleFonts.unbounded(
        fontSize: 15,
        fontWeight: FontWeight.w800,
        height: 1.3,
        letterSpacing: -0.3,
        color: c,
      );
}
