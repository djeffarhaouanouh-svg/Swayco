import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_strings.dart';

/// Quelle interface portugaise : celle du Brésil ou celle du Portugal.
///
/// C'est un choix d'AFFICHAGE, mémorisé sur l'appareil : le code de langue du
/// compte reste `pt` (voix, traduction, filtres de Découvrir : rien ne change).
/// Pas de choix encore fait → le Brésil si le téléphone est réglé sur le Brésil,
/// sinon le Portugal.
abstract final class UiVariant {
  static const String _key = 'ui_pt_brazilian';

  static bool get _deviceIsBrazil {
    try {
      return PlatformDispatcher.instance.locale.countryCode == 'BR';
    } catch (_) {
      return false;
    }
  }

  /// À appeler avant d'afficher quoi que ce soit en portugais (au démarrage).
  static Future<void> load() async {
    bool? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getBool(_key);
    } catch (e) {
      debugPrint('UiVariant.load failed: $e');
    }
    AppStrings.ptBrazilian.value = saved ?? _deviceIsBrazil;
  }

  /// Vrai = Português (Brasil), faux = Português (Portugal). Appliqué tout de
  /// suite (l'app se redessine) puis mémorisé.
  static Future<void> setPortugueseBrazilian(bool brazilian) async {
    AppStrings.ptBrazilian.value = brazilian;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, brazilian);
    } catch (e) {
      debugPrint('UiVariant.set failed: $e');
    }
  }
}
