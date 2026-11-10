import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_strings.dart';
import '../services/revenue_cat.dart';
import 'failure_sheet.dart';

/// Les feuilles d'échec du paiement (écrans 1a, 1b, 1c, 1d, et « réseau » de 2a).
/// `PurchaseOutcome.cancelled` reste SILENCIEUX : la personne a fermé la fenêtre
/// du store, on n'affiche rien.

bool get _isApple => defaultTargetPlatform == TargetPlatform.iOS;
String get _storeName => _isApple ? 'App Store' : 'Google Play';
String get _accountName => _isApple ? 'Apple' : 'Google';

Future<void> _open(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('open $url failed: $e');
  }
}

void _openSupport() => _open('mailto:support@swayco.app');

void _openBilling() => _open(
      _isApple
          ? 'https://apps.apple.com/account/billing'
          : 'https://play.google.com/store/paymentmethods',
    );

/// Affiche la feuille qui correspond à [outcome]. Ne fait rien pour `success`
/// et `cancelled`. Renvoie quand la feuille est refermée.
///
/// - [onRetry] : relance l'achat (1a, 1b, réseau).
/// - [onRestore] : « Restaurer mes achats » (1c).
/// - [onActivated] : appelé si le droit Pro s'active pendant que la feuille 1c
///   est ouverte (la feuille se ferme d'elle-même).
Future<void> showPurchaseFailure(
  BuildContext context,
  PurchaseOutcome outcome, {
  required VoidCallback onRetry,
  VoidCallback? onRestore,
  VoidCallback? onActivated,
}) async {
  switch (outcome) {
    case PurchaseOutcome.success:
    case PurchaseOutcome.cancelled:
      return;
    case PurchaseOutcome.error:
      // 1a — carte refusée : rien n'a été débité.
      return showFailureSheet(
        context,
        icon: Icons.credit_card_off_rounded,
        tone: FailureTone.red,
        title: AppStrings.t('fail_pay_declined_title'),
        body: AppStrings.t('fail_pay_declined_body'),
        primaryLabel: AppStrings.t('fail_retry'),
        primaryIcon: Icons.refresh_rounded,
        onPrimary: onRetry,
        secondaryLabel: AppStrings.t('fail_change_payment'),
        onSecondary: _openBilling,
        linkLabel: AppStrings.t('fail_support_help'),
        onLink: _openSupport,
      );
    case PurchaseOutcome.unavailable:
      // 1b — le store ne répond pas. La raison technique (utile en TestFlight)
      // est derrière un appui long sur le titre.
      return showFailureSheet(
        context,
        icon: Icons.storefront_rounded,
        tone: FailureTone.blue,
        title: AppStrings.t('fail_store_title'),
        body: AppStrings.t('fail_store_body', args: {'store': _storeName}),
        primaryLabel: AppStrings.t('fail_retry'),
        primaryIcon: Icons.refresh_rounded,
        onPrimary: onRetry,
        secondaryLabel: AppStrings.t('fail_close'),
        onSecondary: () {},
        technicalDetail: RevenueCat.lastUnavailableReason.isEmpty
            ? null
            : RevenueCat.lastUnavailableReason,
      );
    case PurchaseOutcome.network:
      // 2a (feuille) — pas de réseau pendant l'achat.
      return showFailureSheet(
        context,
        icon: Icons.wifi_off_rounded,
        tone: FailureTone.grey,
        title: AppStrings.t('fail_offline_title'),
        body: AppStrings.t('fail_offline_body'),
        primaryLabel: AppStrings.t('fail_retry'),
        primaryIcon: Icons.refresh_rounded,
        onPrimary: onRetry,
        secondaryLabel: AppStrings.t('fail_close'),
        onSecondary: () {},
      );
    case PurchaseOutcome.pendingActivation:
      // 1c — le store a débité, le droit Pro n'est pas encore actif. On vérifie
      // toutes les 5 s pendant 30 s ; s'il arrive, la feuille se ferme seule.
      var open = true;
      var tries = 0;
      Timer? timer;
      timer = Timer.periodic(const Duration(seconds: 5), (t) async {
        tries++;
        if (!open) {
          t.cancel();
          return;
        }
        bool active = false;
        try {
          active = await RevenueCat.hasEntitlement(RevenueCat.proEntitlementId);
        } catch (_) {}
        if (active && open && context.mounted) {
          t.cancel();
          Navigator.of(context).pop();
          onActivated?.call();
        } else if (tries >= 6) {
          t.cancel();
        }
      });
      await showFailureSheet(
        context,
        icon: Icons.hourglass_top_rounded,
        tone: FailureTone.yellow,
        chipLabel: AppStrings.t('fail_paid_chip'),
        title: AppStrings.t('fail_paid_title'),
        body: AppStrings.t('fail_paid_body'),
        primaryLabel: AppStrings.t('fail_restore'),
        primaryIcon: Icons.restore_rounded,
        onPrimary: onRestore ?? () {},
        linkLabel: AppStrings.t('fail_support_help'),
        onLink: _openSupport,
      );
      open = false;
      timer.cancel();
      return;
  }
}

/// 1d — la restauration n'a trouvé aucun abonnement Pro.
Future<void> showNothingToRestoreSheet(BuildContext context) {
  return showFailureSheet(
    context,
    icon: Icons.history_rounded,
    tone: FailureTone.blue,
    title: AppStrings.t('fail_nothing_title'),
    body: AppStrings.t('fail_nothing_body', args: {'account': _accountName}),
    primaryLabel: AppStrings.t('fail_see_offers'),
    onPrimary: () {},
    secondaryLabel: AppStrings.t('fail_close'),
    onSecondary: () {},
  );
}
