import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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
