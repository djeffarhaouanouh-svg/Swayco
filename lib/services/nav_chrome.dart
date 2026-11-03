// lib/services/nav_chrome.dart  — REMPLACE le fichier existant en entier.
import 'dart:async';

import 'package:flutter/foundation.dart';

/// Lets a page ask the shell to get out of the way.
///
/// Deux façons de cacher la barre :
///  • [hide] / [show] — le panneau d'infos de Discover (inchangé) : la barre
///    glisse vers le bas, aucune poignée, le panneau possède le bas de l'écran.
///  • [hideAuto] / [showAfter] — la barre se range d'elle-même pendant qu'on
///    défile (Chat, Likes, Profil) ou qu'on glisse une carte (Discover), puis
///    revient après un délai. Une poignée s'affiche à sa place ([autoHidden]) :
///    un tap la rappelle tout de suite.
abstract final class NavChrome {
  /// Vrai quand la barre est hors écran, quelle qu'en soit la raison.
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);

  /// Vrai seulement quand c'est le défilement / le glisser qui l'a cachée.
  /// RootShell s'en sert pour afficher la poignée.
  static final ValueNotifier<bool> autoHidden = ValueNotifier<bool>(false);

  /// Hauteur de la zone tactile de la poignée, collée au bas de l'écran.
  /// Discover garde ses boutons au-dessus de cette zone.
  static const double handleZone = 44;

  static Timer? _timer;

  static void hide() {
    _timer?.cancel();
    autoHidden.value = false;
    hidden.value = true;
  }

  static void show() {
    _timer?.cancel();
    autoHidden.value = false;
    hidden.value = false;
  }

  /// Range la barre (défilement / glisser). Sans effet si le panneau d'infos
  /// de Discover l'a déjà cachée : lui seul la rend.
  static void hideAuto() {
    if (hidden.value && !autoHidden.value) return;
    _timer?.cancel();
    autoHidden.value = true;
    hidden.value = true;
  }

  /// Ramène la barre après [delay] si c'est un rangement automatique.
  /// Un nouveau [hideAuto] annule le compte à rebours.
  static void showAfter(Duration delay) {
    if (!autoHidden.value) return;
    _timer?.cancel();
    _timer = Timer(delay, show);
  }
}
