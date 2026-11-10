import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Écran « Pas de connexion » (2a), posé par-dessus l'app quand il n'y a AUCUN
/// réseau depuis plus de 2 s. Il se retire seul au retour du réseau (fondu
/// 180 ms), réessaie toutes les 5 s (compte à rebours affiché), et le bouton
/// force un essai immédiat.
///
/// Il vit dans `RootShell` : un appel est une route poussée PAR-DESSUS, donc cet
/// écran ne s'y affiche jamais pendant un appel (et ne touche pas au code de
/// l'appel).
class OfflineOverlay extends StatefulWidget {
  const OfflineOverlay({super.key});

  @override
  State<OfflineOverlay> createState() => _OfflineOverlayState();
}

class _OfflineOverlayState extends State<OfflineOverlay> {
  static const _graceMs = 2000;
  static const _retryEvery = 5;

  final Connectivity _conn = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _grace;
  Timer? _tick;
  bool _offline = false; // état brut du réseau
  bool _shown = false; // affiché (après le délai de grâce)
  bool _everShown = false;
  int _left = _retryEvery;

  static bool _isOffline(List<ConnectivityResult> r) =>
      r.isNotEmpty && r.every((e) => e == ConnectivityResult.none);

  @override
  void initState() {
    super.initState();
    _check();
    _sub = _conn.onConnectivityChanged.listen(_apply, onError: (_) {});
  }

  Future<void> _check() async {
    try {
      _apply(await _conn.checkConnectivity());
    } catch (e) {
      debugPrint('connectivity check failed: $e');
    }
  }

  void _apply(List<ConnectivityResult> r) {
    final off = _isOffline(r);
    if (off == _offline && (!off || _grace != null || _shown)) return;
    _offline = off;
    _grace?.cancel();
    _grace = null;
    if (off) {
      _grace = Timer(const Duration(milliseconds: _graceMs), () {
        if (!mounted || !_offline) return;
        setState(() {
          _shown = true;
          _everShown = true;
          _left = _retryEvery;
        });
        _startTick();
      });
    } else {
      _tick?.cancel();
      if (mounted && _shown) setState(() => _shown = false);
    }
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= 1) {
        setState(() => _left = _retryEvery);
        _check();
      } else {
        setState(() => _left--);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _grace?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !_shown,
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: still ? Duration.zero : const Duration(milliseconds: 180),
        // Une fois montré, le rideau reste dans l'arbre (opacité 0, sans tap) :
        // sinon le fondu de sortie serait coupé net.
        child: _everShown
            ? _OfflineScreen(
                left: _left,
                onRetry: () {
                  setState(() => _left = _retryEvery);
                  _check();
                },
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _OfflineScreen extends StatelessWidget {
  const _OfflineScreen({required this.left, required this.onRetry});

  final int left;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final ring = SC.light
        ? (
            fill: const Color(0xFF04123A).withValues(alpha: 0.05),
            border: const Color(0xFF04123A).withValues(alpha: 0.14),
            icon: const Color(0xFF04123A),
          )
        : (
            fill: Colors.white.withValues(alpha: 0.06),
            border: Colors.white.withValues(alpha: 0.2),
            icon: Colors.white.withValues(alpha: 0.92),
          );
    return Material(
      color: SC.light ? const Color(0xFFF5F7FF) : SC.dBg,
      child: Stack(
        children: [
          // Le halo bleu du haut, comme les autres écrans.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 320,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 1.1,
                  colors: [
                    SC.brandBlue.withValues(alpha: SC.light ? 0.18 : 0.42),
                    SC.brandCyan.withValues(alpha: SC.light ? 0.08 : 0.12),
                    SC.brandBlueDeep.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.42, 0.75],
                ),
              ),
            ),
          ),
          Positioned(
            top: safe.top + 110,
            left: 0,
            right: 0,
            child: Column(
              children: [
                SizedBox(
                  width: 260,
                  height: 260,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      for (final d in const [(260.0, 0.14), (172.0, 0.20)])
                        Container(
                          width: d.$1,
                          height: d.$1,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: PopupTokens.ink.withValues(alpha: d.$2),
                            ),
                          ),
                        ),
                      Container(
                        width: 116,
                        height: 116,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: ring.fill,
                          border: Border.all(color: ring.border, width: 1.2),
                        ),
                        child: Icon(Icons.wifi_off_rounded,
                            size: 54, color: ring.icon),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    AppStrings.t('fail_offline_title'),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    style: popupDisplay(
                      fontSize: 30,
                      letterSpacing: -0.9,
                      height: 1.15,
                      color: PopupTokens.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 310),
                  child: Text(
                    AppStrings.t('fail_offline_body'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                      color: PopupTokens.textBody,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: safe.bottom + 50,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppStrings.t('fail_offline_countdown', args: {'s': '$left'}),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    letterSpacing: 0.6,
                    color: PopupTokens.ink.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(
                      backgroundColor: SC.accent,
                      foregroundColor: SC.onAccent,
                      shape: const StadiumBorder(),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.refresh_rounded, size: 22),
                          const SizedBox(width: 8),
                          Text(
                            AppStrings.t('fail_retry'),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
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
        ],
      ),
    );
  }
}
