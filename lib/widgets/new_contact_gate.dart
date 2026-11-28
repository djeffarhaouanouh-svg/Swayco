import 'package:flutter/material.dart';

import '../screens/paywall_screen.dart';
import '../services/analytics.dart';
import '../services/app_strings.dart';
import '../services/new_contacts.dart';
import '../services/revenue_cat.dart';
import 'swayco_popups_extra.dart';

/// À appeler avant d'écrire à quelqu'un. `false` : la limite du jour est
/// atteinte (l'écran Pro a été proposé, et refusé).
Future<bool> allowNewContact(
  BuildContext context, {
  required String meId,
  required String peerId,
  required String source,
}) async {
  if (await NewContacts.take(meId: meId, peerId: peerId)) return true;
  if (!context.mounted) return false;
  Analytics.track('new_contacts_limit', props: {'source': source});
  final goPro = await showSwaycoNotice(
    context: context,
    icon: Icons.lock_clock_rounded,
    message: AppStrings.t('new_contacts_limit',
        args: {'n': '${NewContacts.freeLimit}'}),
    buttonLabel: AppStrings.t('new_contacts_cta'),
    secondaryLabel: AppStrings.t('cancel'),
  );
  if (goPro != true || !context.mounted) return false;
  Analytics.track('paywall_open', props: {'source': source});
  await showPaywallSheet(context, source: source);
  return RevenueCat.proActive.value;
}
