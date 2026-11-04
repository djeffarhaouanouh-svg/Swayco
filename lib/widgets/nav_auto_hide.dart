// lib/widgets/nav_auto_hide.dart  — NOUVEAU fichier.
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
    required this.tab,
    required this.child,
    this.returnDelay = const Duration(milliseconds: 500),
  });

  /// `NavTab.chat`, `NavTab.demandes` ou `NavTab.profile`.
  final int tab;
  final Widget child;
  final Duration returnDelay;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
        if (NavTab.index.value != tab) return false;
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
