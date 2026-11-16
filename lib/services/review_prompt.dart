import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La demande d'avis (les étoiles) de l'App Store / Google Play.
///
/// La fenêtre est celle du SYSTÈME (Apple et Google en imposent l'usage : pas de
/// fenêtre maison, pas de tri des contents, pas de cadeau contre une note).
/// Elle s'affiche par-dessus l'appli, sans la quitter. On ne contrôle pas le
/// reste : les magasins limitent le nombre d'affichages (3 par an sur iOS) et ne
/// disent pas si la fenêtre est vraiment apparue.
///
/// Déclencheur : après le [_kAfterMessages]ᵉ message ENVOYÉ depuis l'appli, une
/// seule fois par installation. Le décompte vit sur l'appareil.
abstract final class ReviewPrompt {
  /// Nombre de messages envoyés après lequel on demande.
  static const int _kAfterMessages = 4;

  /// Petit délai : la fenêtre ne doit pas surgir pile pendant l'envoi.
  static const Duration _kDelay = Duration(seconds: 3);

  static const String _kCountKey = 'review_messages_sent';
  static const String _kAskedKey = 'review_asked';

  /// À appeler chaque fois qu'un message de la personne est parti.
  static Future<void> noteMessageSent() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kAskedKey) ?? false) return;
      final n = (prefs.getInt(_kCountKey) ?? 0) + 1;
      await prefs.setInt(_kCountKey, n);
      if (n < _kAfterMessages) return;
      // Marqué AVANT la demande : même si le magasin n'affiche rien, on ne
      // redemande pas.
      await prefs.setBool(_kAskedKey, true);
      unawaited(Future<void>.delayed(_kDelay, _request));
    } catch (_) {
      // Un décompte raté ne doit jamais gêner l'envoi d'un message.
    }
  }

  static Future<void> _request() async {
    try {
      final review = InAppReview.instance;
      if (await review.isAvailable()) await review.requestReview();
    } catch (_) {
      // Pas de fenêtre disponible (appareil, magasin) : on n'insiste pas.
    }
  }
}
