import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Réglage « Apparence » : Système / Clair / Sombre. Mémorisé sur l'appareil ;
/// `MaterialApp.themeMode` l'écoute, donc le changement est immédiat.
abstract final class AppTheme {
  static const String _key = 'appearance_mode';

  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  /// À appeler au démarrage, avant `runApp`.
  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      mode.value = switch (p.getString(_key)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      // Lecture impossible : on suit le téléphone.
    }
  }

  static Future<void> set(ThemeMode m) async {
    mode.value = m;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, m.name);
    } catch (_) {}
  }
}
