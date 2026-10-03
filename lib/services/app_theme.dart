import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Les apparences au choix dans les Réglages.
enum Appearance {
  /// Suit le téléphone (clair ou sombre).
  system,

  /// Blanc + halo de marque.
  light,

  /// Noir bleuté #0A0F1C + halo de marque (18d).
  dark,

  /// Le noir classique #0E0E0E, sans halo (l'ancien fond).
  black,
}

/// Réglage « Apparence ». Mémorisé sur l'appareil ; `MaterialApp` l'écoute,
/// donc le changement est immédiat.
abstract final class AppTheme {
  static const String _key = 'appearance_mode';

  static final ValueNotifier<Appearance> appearance =
      ValueNotifier<Appearance>(Appearance.system);

  /// Le `ThemeMode` Flutter correspondant (le noir classique est un sombre).
  static ThemeMode themeModeOf(Appearance a) => switch (a) {
        Appearance.system => ThemeMode.system,
        Appearance.light => ThemeMode.light,
        Appearance.dark || Appearance.black => ThemeMode.dark,
      };

  /// À appeler au démarrage, avant `runApp`.
  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      appearance.value = switch (p.getString(_key)) {
        'light' => Appearance.light,
        'dark' => Appearance.dark,
        'black' => Appearance.black,
        _ => Appearance.system,
      };
    } catch (_) {
      // Lecture impossible : on suit le téléphone.
    }
  }

  /// Reconstruit TOUT l'arbre. Les couleurs SC.* sont lues à la construction
  /// seulement (aucune dépendance Flutter à suivre) : sans ça, un écran déjà
  /// affiché ou gardé en vie (onglets, page Réglages ouverte…) garderait ses
  /// anciennes couleurs — du blanc en mode sombre, ou l'inverse.
  static void rebuildAll() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) mark(root);
  }

  static Future<void> set(Appearance a) async {
    appearance.value = a;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, a.name);
    } catch (_) {}
  }
}
