import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';

/// Outcome of a store purchase attempt — plain enum so callers (the paywall)
/// never need to import `purchases_flutter` types directly.
enum PurchaseOutcome { success, cancelled, unavailable, error }

/// RevenueCat wrapper for in-app subscriptions on **iOS / Android**.
///
/// The WEB build keeps using the Stripe checkout ([StripeApi]) — RevenueCat's
/// native SDK has no web purchasing — so every method here no-ops (returns an
/// empty / false result) on web and other unsupported platforms.
///
/// Offerings, products and the entitlement id are configured on the
/// RevenueCat dashboard; this client only:
///   * configures the SDK with the public store key,
///   * ties purchases to the signed-in Supabase user ([identify] / [logOut]),
///   * exposes fetch-offerings / purchase / restore / entitlement helpers.
///
/// The keys below are *public* SDK keys (safe to ship in the binary — they are
/// not secrets, unlike the Stripe / Supabase service keys).
abstract final class RevenueCat {
  /// iOS public SDK key (from the RevenueCat dashboard → API keys → Apple).
  static const String _appleApiKey = 'appl_RgjIujVqOxrRtMNPtBIfCtLfSZI';

  /// Android public SDK key (from the RevenueCat dashboard → API keys → Google).
  static const String _googleApiKey = 'goog_peRXRVHvLKErMZAtOqvGlbPuBvu';

  /// Package identifier in the RevenueCat offering — the same on both stores
  /// (iOS product `pro_monthly`, Android `pro_monthly:monthly`).
  static const String proPackageId = 'pro_monthly';
  static const String proEntitlementId = 'pro';

  /// Consumable Boost package (iOS `Boost_1`, Android `boost_1`). No
  /// entitlement: the backend webhook credits it (profiles.boosted_until).
  static const String boostPackageId = 'Boost';

  /// Whether the `pro` entitlement is active for the current store user. Kept
  /// current by the SDK listener and after every purchase / restore / login.
  static final ValueNotifier<bool> proActive = ValueNotifier(false);

  static bool _configured = false;

  /// True once [init] has successfully run on this device.
  static bool get isConfigured => _configured;

  /// True only on a platform whose native RevenueCat SDK we support
  /// (iOS / Android, never web).
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Configure the SDK once at app start. Safe to call on web / unsupported
  /// platforms (returns immediately). [appUserId] ties purchases to a known
  /// user when one is already signed in at boot.
  static Future<void> init({String? appUserId}) async {
    if (_configured || !isSupported) return;
    final apiKey =
        defaultTargetPlatform == TargetPlatform.iOS ? _appleApiKey : _googleApiKey;
    if (apiKey.isEmpty) {
      debugPrint('RevenueCat: no API key for this platform — skipping');
      return;
    }
    try {
      await Purchases.setLogLevel(kDebugMode ? LogLevel.debug : LogLevel.warn);
      await Purchases.configure(
        PurchasesConfiguration(apiKey)..appUserID = appUserId,
      );
      _configured = true;
      Purchases.addCustomerInfoUpdateListener(_onCustomerInfo);
      unawaited(Purchases.getCustomerInfo().then(_onCustomerInfo, onError: (_) {}));
      debugPrint('RevenueCat configured (appUserID=${appUserId ?? '<anon>'})');
    } catch (e) {
      debugPrint('RevenueCat configure failed: $e');
    }
  }

  /// Attach purchases to the signed-in Supabase user id (call on sign-in).
  static Future<void> identify(String userId) async {
    if (!_configured || userId.isEmpty) return;
    try {
      _onCustomerInfo((await Purchases.logIn(userId)).customerInfo);
    } catch (e) {
      debugPrint('RevenueCat logIn failed: $e');
    }
  }

  /// Detach the user on sign-out (reverts to an anonymous RevenueCat id).
  static Future<void> logOut() async {
    if (!_configured) return;
    proActive.value = false;
    try {
      await Purchases.logOut();
    } catch (e) {
      debugPrint('RevenueCat logOut failed: $e');
    }
  }

  /// The current offering's purchasable packages. Empty when unsupported, not
  /// configured, or no current offering is set on the dashboard.
  static Future<List<Package>> fetchPackages() async {
    if (!_configured) return const [];
    try {
      final offerings = await Purchases.getOfferings();
      return offerings.current?.availablePackages ?? const [];
    } catch (e) {
      debugPrint('RevenueCat getOfferings failed: $e');
      return const [];
    }
  }

  /// Buy [package]. Returns the updated [CustomerInfo] on success, or null on
  /// cancellation / failure (the SDK shows the native store sheet itself).
  static Future<CustomerInfo?> purchase(Package package) async {
    if (!_configured) return null;
    try {
      final result = await Purchases.purchase(PurchaseParams.package(package));
      return result.customerInfo;
    } catch (e) {
      // Includes user cancellation — caller treats null as "no change".
      debugPrint('RevenueCat purchase failed/cancelled: $e');
      return null;
    }
  }

  /// The package whose RevenueCat identifier is [packageId] in the current
  /// offering. Matched on the package id, never the store product id, which
  /// differs per store (Android appends the base plan: `pro_monthly:monthly`).
  static Future<Package?> _package(String packageId) async {
    final packages = await fetchPackages();
    for (final p in packages) {
      if (p.identifier.toLowerCase() == packageId.toLowerCase()) return p;
    }
    debugPrint(
      'RevenueCat: package "$packageId" not in current offering '
      '(has: ${packages.map((p) => p.identifier).join(', ')})',
    );
    return null;
  }

  /// Store-localized price of [packageId] (e.g. "6,99 €"), or null when the
  /// package can't be loaded.
  static Future<String?> priceOf(String packageId) async =>
      (await _package(packageId))?.storeProduct.priceString;

  /// High-level purchase: buy the offering package [packageId] and report
  /// whether [entitlementId] is active afterwards. Keeps `purchases_flutter`
  /// types out of the UI.
  static Future<PurchaseOutcome> purchasePackage({
    required String packageId,
    required String entitlementId,
  }) async {
    if (!_configured) return PurchaseOutcome.unavailable;
    final pkg = await _package(packageId);
    if (pkg == null) return PurchaseOutcome.unavailable;
    try {
      final result = await Purchases.purchase(PurchaseParams.package(pkg));
      _onCustomerInfo(result.customerInfo);
      return result.customerInfo.entitlements.active.containsKey(entitlementId)
          ? PurchaseOutcome.success
          : PurchaseOutcome.error;
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return PurchaseOutcome.cancelled;
      }
      debugPrint('RevenueCat purchase error: ${e.message}');
      return PurchaseOutcome.error;
    } catch (e) {
      debugPrint('RevenueCat purchase error: $e');
      return PurchaseOutcome.error;
    }
  }

  /// Buy the consumable [packageId] once. Success = the store charged; what it
  /// grants is credited server-side by the RevenueCat webhook.
  static Future<PurchaseOutcome> purchaseConsumable(String packageId) async {
    if (!_configured) return PurchaseOutcome.unavailable;
    final pkg = await _package(packageId);
    if (pkg == null) return PurchaseOutcome.unavailable;
    try {
      await Purchases.purchase(PurchaseParams.package(pkg));
      return PurchaseOutcome.success;
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return PurchaseOutcome.cancelled;
      }
      debugPrint('RevenueCat consumable error: ${e.message}');
      return PurchaseOutcome.error;
    } catch (e) {
      debugPrint('RevenueCat consumable error: $e');
      return PurchaseOutcome.error;
    }
  }

  /// Re-attach existing purchases on a reinstall / new device.
  static Future<CustomerInfo?> restore() async {
    if (!_configured) return null;
    try {
      return await Purchases.restorePurchases();
    } catch (e) {
      debugPrint('RevenueCat restore failed: $e');
      return null;
    }
  }

  /// Restore purchases and return the set of entitlement ids active after —
  /// e.g. `{'pro'}`. Empty when nothing to restore.
  static Future<Set<String>> restoreEntitlements() async {
    if (!_configured) return const {};
    try {
      final info = await Purchases.restorePurchases();
      _onCustomerInfo(info);
      return info.entitlements.active.keys.toSet();
    } catch (e) {
      debugPrint('RevenueCat restore failed: $e');
      return const {};
    }
  }

  /// True when [entitlementId] is currently active for the signed-in user.
  static Future<bool> hasEntitlement(String entitlementId) async {
    if (!_configured) return false;
    try {
      final info = await Purchases.getCustomerInfo();
      return info.entitlements.active.containsKey(entitlementId);
    } catch (e) {
      debugPrint('RevenueCat getCustomerInfo failed: $e');
      return false;
    }
  }

  static void _onCustomerInfo(CustomerInfo info) {
    proActive.value = info.entitlements.active.containsKey(proEntitlementId);
  }
}
