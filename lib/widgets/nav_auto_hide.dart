// lib/widgets/nav_auto_hide.dart  — NOUVEAU fichier.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/nav_chrome.dart';
import '../services/nav_tab.dart';

/// Enveloppe la zone qui défile d'un onglet (Chat, Likes, Profil) : la barre
/// de navigation se range dès que la liste bouge et revient [returnDelay]
/// après l'arrêt du défilement (inertie comprise).
///
/// - Ne réagit qu'au défilement vertical de premier niveau : les listes
///   horizontales ou imbriquées sont ignorées.
/// - Ne réagit que si l'onglet [tab] est celui affiché (le PageView garde les
///   autres pages vivantes en arrière-plan).
/// - Le rebond au-delà des bords (tirer pour rafraîchir) ne la cache pas.
/// - En haut de liste, la barre revient seule.
class NavAutoHide extends StatelessWidget {
  const NavAutoHide({
    super.key,
    this.tab,
    required this.child,
    this.returnDelay = const Duration(milliseconds: 500),
  });

  /// `NavTab.chat`, `NavTab.demandes` ou `NavTab.profile`. `null` = une page
  /// POUSSÉE par-dessus les onglets (le profil d'un pair) : pas d'onglet à
  /// comparer, elle règle la barre pour elle-même.
  final int? tab;
  final Widget child;
  final Duration returnDelay;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
        if (tab != null && NavTab.index.value != tab) return false;
        if (n is ScrollUpdateNotification) {
          final m = n.metrics;
          if ((n.scrollDelta ?? 0).abs() <= 1) return false;
          if (m.pixels <= 8) {
            if (NavChrome.autoHidden.value) NavChrome.show();
          } else if (m.pixels <= m.maxScrollExtent) {
            NavChrome.hideAuto();
          }
        } else if (n is ScrollEndNotification) {
          NavChrome.showAfter(returnDelay);
        }
        return false;
      },
      child: child,
    );
  }
}

/// Un tap n'importe où sur l'écran rappelle la barre quand elle est rangée
/// (par le défilement ou le glissement d'une carte). À poser au-dessus des pages
/// et au-dessous de la barre : il ÉCOUTE les doigts sans les bloquer, le bouton
/// ou la carte dessous reçoit son tap comme d'habitude.
///
/// Un « tap » = doigt levé à moins de 12 px d'où il s'est posé, en moins de
/// 350 ms : un défilement ou un glissement de carte ne la rappelle donc pas.
class NavTapRestore extends StatefulWidget {
  const NavTapRestore({super.key});

  @override
  State<NavTapRestore> createState() => _NavTapRestoreState();
}

class _NavTapRestoreState extends State<NavTapRestore> {
  Offset? _down;
  Timer? _tooLong;
  bool _stillATap = false;

  @override
  void dispose() {
    _tooLong?.cancel();
    super.dispose();
  }

  void _reset() {
    _tooLong?.cancel();
    _down = null;
    _stillATap = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _tooLong?.cancel();
        _down = e.position;
        _stillATap = true;
        // Au-delà de 350 ms ce n'est plus un tap (appui long, début de geste).
        _tooLong = Timer(const Duration(milliseconds: 350), () {
          _stillATap = false;
        });
      },
      onPointerUp: (e) {
        final d = _down;
        final tap = _stillATap && d != null && (e.position - d).distance < 12;
        _reset();
        if (tap) NavChrome.show();
      },
      onPointerCancel: (_) => _reset(),
    );
  }
}
/// La barre de navigation d'une page POUSSÉE par-dessus les onglets (le profil
/// d'un pair), avec le même mouvement que celle du shell : elle glisse vers le
/// bas en se resserrant à 55 % quand [NavChrome] la range, et revient.
class NavTuckAway extends StatelessWidget {
  const NavTuckAway({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NavChrome.hidden,
      builder: (context, hidden, child) {
        final auto = NavChrome.autoHidden.value;
        final still = MediaQuery.disableAnimationsOf(context);
        final slideMs = auto ? 420 : 260;
        return IgnorePointer(
          ignoring: hidden,
          child: AnimatedSlide(
            offset: hidden ? const Offset(0, 1.8) : Offset.zero,
            duration: still ? Duration.zero : Duration(milliseconds: slideMs),
            curve: Curves.easeOutCubic,
            child: AnimatedScale(
              scale: auto && hidden ? 0.55 : 1.0,
              alignment: Alignment.bottomCenter,
              duration: still ? Duration.zero : Duration(milliseconds: slideMs),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: hidden ? 0 : 1,
                duration: still
                    ? Duration.zero
                    : Duration(milliseconds: auto ? 300 : 200),
                child: child,
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Le trait que laisse la barre rangée par le défilement : un tap, ou un
/// glissement vers le haut, la rappelle tout de suite. À poser dans un
/// `Positioned(left: 0, right: 0, bottom: 0, height: NavChrome.handleZone)`.
class NavHandle extends StatelessWidget {
  const NavHandle({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NavChrome.autoHidden,
      builder: (context, auto, _) => IgnorePointer(
        ignoring: !auto,
        child: AnimatedOpacity(
          opacity: auto ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 250),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: NavChrome.show,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -150) NavChrome.show();
            },
            child: Align(
              alignment: const Alignment(0, 0.45),
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
