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
  ///
  /// `$rc_monthly`, not `pro_monthly`: the package was created through
  /// RevenueCat's default-package flow, which assigns this reserved
  /// identifier and doesn't allow renaming it from the dashboard. Matching
  /// on the display name would have worked too, but the package identifier
  /// is the value `Purchases.getOfferings()` actually exposes as
  /// `Package.identifier` — see [_package].
  static const String proPackageId = '\$rc_monthly';
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
      _configureError = '$e';
      debugPrint('RevenueCat configure failed: $e');
    }
  }

  static String _configureError = '';

  /// Short reason for the last "unavailable" outcome — surfaced in the
  /// paywall/Boost snackbar because TestFlight builds have no readable
  /// console, and guessing the cause cost several build cycles.
  static String lastUnavailableReason = '';

  /// Attach purchases to the signed-in Supabase user id (call on sign-in).
  static Future<void> identify(String userId) async {
    if (!_configured || userId.isEmpty) return;
    try {
      _onCustomerInfo((await Purchases.logIn(userId)).customerInfo);
    } catch (e) {
      debugPrint('RevenueCat logIn failed: $e');
    }
  }

  /// Hand RevenueCat the AppsFlyer device id so it reports purchases,
  /// renewals and refunds to AppsFlyer **server-side** (see [Attribution]).
  /// Called once at boot; a failure only costs purchase attribution, never
  /// the purchase itself.
  static Future<void> setAppsflyerId(String appsflyerId) async {
    if (!_configured || appsflyerId.isEmpty) return;
    try {
      // The id alone is not enough: RevenueCat also needs the device
      // identifiers (IDFA / IDFV / GAID / IP) to match a purchase back to the
      // install AppsFlyer attributed. RevenueCat's own integration guide calls
      // both, and warns that "if the AppsFlyer ID is missing, some events may
      // not be delivered" — collecting only half the pair is how a purchase
      // silently never shows up on the AppsFlyer side.
      await Purchases.collectDeviceIdentifiers();
      await Purchases.setAppsflyerID(appsflyerId);
    } catch (e) {
      debugPrint('RevenueCat setAppsflyerID failed: $e');
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
    if (!_configured) {
      lastUnavailableReason = _configureError.isEmpty
          ? 'not configured'
          : 'configure failed: $_configureError';
      return const [];
    }
    try {
      final offerings = await Purchases.getOfferings();
      final current = offerings.current;
      if (current == null) {
        lastUnavailableReason =
            'no current offering (all: ${offerings.all.keys.join(', ')})';
        return const [];
      }
      if (current.availablePackages.isEmpty) {
        lastUnavailableReason =
            'offering "${current.identifier}" has 0 packages from the store';
      }
      return current.availablePackages;
    } on PlatformException catch (e) {
      lastUnavailableReason =
          'getOfferings: ${e.code} ${e.message ?? ''}'.trim();
      debugPrint('RevenueCat getOfferings failed: $e');
      return const [];
    } catch (e) {
      lastUnavailableReason = 'getOfferings: $e';
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

  /// Store product id behind each package id we look up, used as a fallback
  /// match: the base id (Android's `:basePlan` suffix stripped) is the same
  /// on both stores up to case (`Boost_1` / `boost_1`).
  static const Map<String, String> _productFallback = {
    proPackageId: 'pro_monthly',
    boostPackageId: 'boost_1',
  };

  /// The package for [packageId] in the current offering — matched on the
  /// RevenueCat package identifier first, then on the store product id, so
  /// a dashboard-side identifier we guessed wrong can't make it vanish.
  static Future<Package?> _package(String packageId) async {
    lastUnavailableReason = '';
    final packages = await fetchPackages();
    final wanted = packageId.toLowerCase();
    final wantedProduct = _productFallback[packageId]?.toLowerCase();
    for (final p in packages) {
      if (p.identifier.toLowerCase() == wanted) return p;
    }
    if (wantedProduct != null) {
      for (final p in packages) {
        final base = p.storeProduct.identifier.split(':').first.toLowerCase();
        if (base == wantedProduct) return p;
      }
    }
    if (packages.isNotEmpty) {
      lastUnavailableReason = 'package "$packageId" missing (have: '
          '${packages.map((p) => '${p.identifier}=${p.storeProduct.identifier}').join(', ')})';
    }
    debugPrint('RevenueCat: $lastUnavailableReason');
    return null;
  }

  /// Exact store ids to ask the store for directly when a package is missing
  /// from the offering. iOS ids are case-sensitive (`Boost_1`); unknown ids
  /// are simply ignored by the store.
  static const Map<String, List<String>> _storeIds = {
    proPackageId: ['pro_monthly'],
    boostPackageId: ['Boost_1', 'boost_1'],
  };

  static void _appendReason(String s) {
    lastUnavailableReason =
        lastUnavailableReason.isEmpty ? s : '$lastUnavailableReason · $s';
  }

  /// When the offering came back without [packageId], ask StoreKit / Play
  /// for the product directly. RevenueCat drops a package from the offering
  /// whenever its store product didn't load, so this both explains why
  /// (appended to [lastUnavailableReason], with the account's storefront)
  /// and lets the purchase go through if the store does know the product.
  static Future<StoreProduct?> _storeProductFallback(String packageId) async {
    final ids = _storeIds[packageId];
    if (ids == null || !_configured) return null;
    var country = '?';
    try {
      country = (await Purchases.storefront)?.countryCode ?? 'none';
    } catch (_) {}
    try {
      final products = await Purchases.getProducts(
        ids,
        productCategory: packageId == boostPackageId
            ? ProductCategory.nonSubscription
            : ProductCategory.subscription,
      );
      _appendReason(
        'store[${ids.join('/')}]='
        '${products.isEmpty ? 'NOT FOUND' : products.first.identifier}'
        ' storefront=$country',
      );
      return products.isEmpty ? null : products.first;
    } on PlatformException catch (e) {
      _appendReason(
        'store lookup: ${e.code} ${e.message ?? ''} storefront=$country',
      );
      return null;
    } catch (e) {
      _appendReason('store lookup: $e storefront=$country');
      return null;
    }
  }

  /// Purchase params for [packageId]: the offering package when present,
  /// else the store product fetched directly, else null (unavailable).
  static Future<PurchaseParams?> _purchaseParams(String packageId) async {
    final pkg = await _package(packageId);
    if (pkg != null) return PurchaseParams.package(pkg);
    final product = await _storeProductFallback(packageId);
    return product == null ? null : PurchaseParams.storeProduct(product);
  }

  /// Store-localized price of [packageId] (e.g. "6,99 €"), or null when the
  /// product can't be loaded at all.
  static Future<String?> priceOf(String packageId) async =>
      (await _package(packageId))?.storeProduct.priceString ??
      (await _storeProductFallback(packageId))?.priceString;

  /// High-level purchase: buy the offering package [packageId] and report
  /// whether [entitlementId] is active afterwards. Keeps `purchases_flutter`
  /// types out of the UI.
  static Future<PurchaseOutcome> purchasePackage({
    required String packageId,
    required String entitlementId,
  }) async {
    final params = await _purchaseParams(packageId);
    if (params == null) return PurchaseOutcome.unavailable;
    try {
      final result = await Purchases.purchase(params);
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
    final params = await _purchaseParams(packageId);
    if (params == null) return PurchaseOutcome.unavailable;
    try {
      await Purchases.purchase(params);
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
