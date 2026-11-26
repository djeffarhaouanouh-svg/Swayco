import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics.dart';
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
  static const _afterMessageKey = 'notif_after_message_done';

  /// Juste après le PREMIER like : « Demande envoyée, on te prévient ? ». C'est
  /// le moment où l'autorisation a un sens (on attend une réponse), au lieu d'un
  /// écran froid à l'inscription. Les nouvelles inscrites qui n'avaient pas
  /// autorisé les notifications ne revenaient jamais : rien ne pouvait leur dire
  /// qu'on leur avait répondu.
  static Future<void> askAfterFirstLike(BuildContext context) => _askOnce(
        context,
        moment: 'first_like',
        doneKey: _afterLikeKey,
        titleKey: 'notif_like_title',
        bodyKey: 'notif_like_body',
      );

  /// Et une seconde chance après le PREMIER message envoyé (en tête-à-tête), pour
  /// qui a dit « plus tard » après son like.
  static Future<void> askAfterFirstMessage(BuildContext context) => _askOnce(
        context,
        moment: 'first_message',
        doneKey: _afterMessageKey,
        titleKey: 'notif_msg_title',
        bodyKey: 'notif_msg_body',
      );

  /// Une seule fois par installation et par moment, et seulement si le système
  /// n'a pas encore été interrogé (refusée une fois, la demande native est
  /// épuisée : on ne harcèle pas). Chaque issue est enregistrée
  /// (`notif_prompt` : granted / later / refused / blocked).
  static Future<void> _askOnce(
    BuildContext context, {
    required String moment,
    required String doneKey,
    required String titleKey,
    required String bodyKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(doneKey) ?? false) return;
      final status = await NotificationClient.notifStatus();
      if (status == 'enabled') {
        await prefs.setBool(doneKey, true);
        return;
      }
      if (status != 'undetermined') {
        if (status == 'denied') {
          await prefs.setBool(doneKey, true);
          _track(moment, 'blocked');
        }
        return;
      }
      // Laisse l'animation du like / l'envoi se poser avant d'ouvrir une fenêtre.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!context.mounted) return;
      await prefs.setBool(doneKey, true);
      final ok = await PermissionPriming.show(
        context,
        icon: Icons.notifications_active_rounded,
        title: AppStrings.t(titleKey),
        body: AppStrings.t(bodyKey),
        confirmLabel: AppStrings.t('notif_prime_enable'),
      );
      if (!ok) {
        _track(moment, 'later');
        return;
      }
      final uid = await DeviceId.getOrCreate();
      final enabled = await NotificationClient.register(uid);
      _track(moment, enabled ? 'granted' : 'refused');
    } catch (e) {
      debugPrint('NotifEnableFlow.$moment failed: $e');
    }
  }

  static void _track(String moment, String result) => Analytics.track(
        'notif_prompt',
        props: {'moment': moment, 'result': result},
      );

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
