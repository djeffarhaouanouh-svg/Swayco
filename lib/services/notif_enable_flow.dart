import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_strings.dart';
import 'device_id.dart';
import 'notification_client.dart';
import 'permission_priming.dart';

/// Orchestrates the full notification opt-in from a contextual entry point
/// (the message-list banner). Three paths, driven by the current OS state:
///
///  - `enabled`      → nothing to do.
///  - `undetermined` → show the priming rationale, then the real OS prompt.
///  - `denied`       → the native prompt is spent; deep-link to Settings.
///
/// Returns true when notifications end up enabled.
abstract final class NotifEnableFlow {
  static const _afterLikeKey = 'notif_after_like_done';

  /// Juste après le PREMIER like : « On te prévient dès qu'elle ou il te
  /// répond ». C'est le moment où l'autorisation a un sens (on attend une
  /// réponse), au lieu d'un écran froid à l'inscription. Les nouvelles inscrites
  /// qui n'avaient pas autorisé les notifications ne revenaient jamais : rien
  /// ne pouvait leur dire qu'on leur avait répondu.
  ///
  /// Une seule fois par installation, et seulement si le système n'a pas encore
  /// été interrogé (refusée une fois, la demande native est épuisée : on ne
  /// harcèle pas).
  static Future<void> askAfterFirstLike(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_afterLikeKey) ?? false) return;
      final status = await NotificationClient.notifStatus();
      if (status == 'enabled') {
        await prefs.setBool(_afterLikeKey, true);
        return;
      }
      if (status != 'undetermined') return;
      // Laisse l'animation du like se poser avant d'ouvrir une fenêtre.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!context.mounted) return;
      await prefs.setBool(_afterLikeKey, true);
      final ok = await PermissionPriming.show(
        context,
        icon: Icons.notifications_active_rounded,
        title: AppStrings.t('notif_like_title'),
        body: AppStrings.t('notif_like_body'),
        confirmLabel: AppStrings.t('notif_prime_enable'),
      );
      if (!ok) return;
      final uid = await DeviceId.getOrCreate();
      await NotificationClient.register(uid);
    } catch (e) {
      debugPrint('NotifEnableFlow.askAfterFirstLike failed: $e');
    }
  }

  static Future<bool> run(BuildContext context) async {
    final status = await NotificationClient.notifStatus();
    if (!context.mounted) return false;
    if (status == 'enabled') return true;

    if (status == 'denied') {
      final ok = await PermissionPriming.show(
        context,
        icon: Icons.notifications_active_rounded,
        title: AppStrings.t('notif_prime_title'),
        body: AppStrings.t('notif_prime_settings_body'),
        confirmLabel: AppStrings.t('notif_prime_open_settings'),
      );
      if (ok) await openAppSettings();
      return false;
    }

    // undetermined — safe to ask. Prime first to protect the one-shot.
    final ok = await PermissionPriming.show(
      context,
      icon: Icons.notifications_active_rounded,
      title: AppStrings.t('notif_prime_title'),
      body: AppStrings.t('notif_prime_body'),
      confirmLabel: AppStrings.t('notif_prime_enable'),
    );
    if (!ok) return false;
    final uid = await DeviceId.getOrCreate();
    return NotificationClient.register(uid);
  }
}
