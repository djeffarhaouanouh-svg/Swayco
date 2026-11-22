import 'dart:async';

import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'revenue_cat.dart';
import 'supabase_service.dart';

/// AppsFlyer install attribution on **iOS / Android** — which campaign or ad
/// brought each install, so Snapchat Ads (and any other network) can be
/// measured and optimised. No-op on web (the SDK has no web support).
///
/// This is NOT a replacement for [Analytics], which feeds the in-house admin
/// dashboard. The two are deliberately separate: Analytics answers "what are
/// users doing", AppsFlyer answers "which ad paid for this user". Only the
/// handful of events an ad network can optimise against are mirrored here.
///
/// The dev key belongs to the AppsFlyer ACCOUNT, not to one app, so the same
/// key serves both the App Store and the Play Store app. Like the RevenueCat
/// keys it is public (it ships inside every binary) and lives here as a
/// constant rather than in dart_defines.env: the iOS workflow passes its
/// defines one by one, and a store build must never go out without it.
///
/// Everything is best-effort: an AppsFlyer failure must never touch boot, a
/// call, or a purchase, so every call swallows and logs its error.
abstract final class Attribution {
  static const String _devKey = 'fd2Nx2z2cuLFk3EoPb2Eb';

  /// Numeric App Store id of Swayco (apps.apple.com/…/id6774043368).
  /// Required by the iOS SDK; ignored on Android.
  static const String _appleAppId = '6774043368';

  static bool _initialized = false;

  /// ATT is a ONE-SHOT iOS prompt, and the session-ready callback below fires
  /// on every foreground. Without this latch the app would re-enter the
  /// request on every return from background — harmless (iOS answers from the
  /// stored decision) but it would delay every session behind a plugin call.
  static bool _attHandled = false;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Initialise the SDK once at app start. [customerUserId] ties the
  /// attribution to the Supabase account when one is already signed in — it
  /// must be set BEFORE the session-ready listener, which can fire (and send
  /// the first session) immediately.
  static Future<void> init({String? customerUserId}) async {
    if (_initialized || !isSupported) return;
    final sdk = AppsFlyerSdk.instance;
    try {
      await sdk.enableDebug(kDebugMode);
      await sdk.init(devKey: _devKey, appId: _appleAppId);
      if (customerUserId != null && customerUserId.isNotEmpty) {
        await sdk.setCustomerUserId(customerUserId);
      }
      _initialized = true;
      // Fires once per foreground cycle (cold launch AND every return from
      // background); each one must send its own session, or only the very
      // first launch is ever counted.
      await sdk.registerSessionReadyListener(() async {
        // iOS: the IDFA is only readable once the user has ANSWERED the ATT
        // prompt, and the answer must land before the first session or the
        // install is attributed without it. SDK 7 dropped the native
        // `timeToWaitForATTUserAuthorization` wait — the app owns this timing
        // now, which is exactly why start() is called here and nowhere else.
        if (_isIOS && !_attHandled) {
          _attHandled = true;
          try {
            await Permission.appTrackingTransparency.request();
          } catch (e) {
            debugPrint('Attribution: ATT request failed: $e');
          }
        }
        try {
          await sdk.start();
          _started = true;
          // The SDK can now accept an acknowledged event: this is the earliest
          // safe moment to report `engaged_user` for accounts that are ALREADY
          // eligible (no new message / friendship needed), and — since it fires
          // on every foreground — the retry point after a failed send.
          checkEngaged();
        } catch (e) {
          debugPrint('Attribution: start failed: $e');
        }
      });
      // Hand the AppsFlyer device id to RevenueCat so IT reports purchases and
      // renewals to AppsFlyer server-side. Done after init() — the id doesn't
      // exist before. Not awaited by the caller's boot path.
      unawaited(_bridgeToRevenueCat(sdk));
    } catch (e) {
      debugPrint('Attribution: init failed: $e');
    }
  }

  /// Server-side purchase reporting: RevenueCat needs the AppsFlyer device id
  /// to tie a subscription to the install that AppsFlyer attributed. Going
  /// through RevenueCat rather than firing `af_purchase` from the app means
  /// renewals, cancellations and refunds — none of which the client ever sees
  /// — are reported too, and that a purchase still counts when the app is
  /// killed right after paying.
  static Future<void> _bridgeToRevenueCat(AppsFlyerSdk sdk) async {
    if (!RevenueCat.isConfigured) return;
    try {
      final uid = await sdk.getAppsFlyerUID();
      if (uid == null || uid.isEmpty) return;
      await RevenueCat.setAppsflyerId(uid);
    } catch (e) {
      debugPrint('Attribution: RevenueCat bridge failed: $e');
    }
  }

  /// Tie later sessions and events to the signed-in account (a fresh sign-in
  /// after boot). No-op until [init] has succeeded, and on web.
  static Future<void> identify(String uid) async {
    if (!_initialized || uid.isEmpty) return;
    try {
      await AppsFlyerSdk.instance.setCustomerUserId(uid);
    } catch (e) {
      debugPrint('Attribution: setCustomerUserId failed: $e');
    }
  }

  /// Fire-and-forget in-app event. Never awaited by callers — an ad network
  /// event must not add latency to a sign-up or a call.
  static void logEvent(String name, [Map<String, dynamic>? values]) {
    if (!_initialized) return;
    unawaited(
      AppsFlyerSdk.instance.logEvent(name, eventValues: values).catchError(
        (Object e) => debugPrint('Attribution: logEvent $name failed: $e'),
      ),
    );
  }

  // ─── Business events ───────────────────────────────────────────────────────
  // AppsFlyer's standard (`af_`) names where one exists — ad networks map
  // those to their own conversion types automatically, which is what lets
  // Snapchat optimise a campaign on them. Purchases are deliberately ABSENT:
  // they arrive server-side through RevenueCat (see [_bridgeToRevenueCat]),
  // and firing them here too would double-count revenue.

  /// A new account was created. [method] is `email`, `google` or `apple`.
  static void logSignUp(String method) =>
      logEvent('af_complete_registration', {'af_registration_method': method});

  /// An existing user signed back in.
  static void logLogin(String method) =>
      logEvent('af_login', {'af_registration_method': method});

  /// Onboarding finished — the first moment the account is actually usable,
  /// and the most meaningful "activated user" signal to optimise a campaign on.
  static void logOnboardingCompleted() => logEvent('af_tutorial_completion');

  /// A call connected. [kind] is the call type (audio / video).
  static void logCallStarted(String kind) =>
      logEvent('call_started', {'kind': kind});

  /// A call ended, with how long it actually lasted.
  static void logCallEnded(String kind, int durationMs) => logEvent(
    'call_ended',
    {'kind': kind, 'duration_ms': durationMs},
  );

  // ─── engaged_user ──────────────────────────────────────────────────────────
  // Once per account, ever: ≥1 CONFIRMED friend AND ≥1 message sent (DM or
  // group; not the Swayco team, not calls). The database decides — the RPC
  // `claim_engaged_user` (migration 0097) checks both conditions and hands the
  // send to exactly one caller, atomically, with a 10-minute lease. The app
  // then fires the event and calls `confirm_engaged_user_sent`. A crash between
  // the two just lets the lease expire, so the next launch retries: no loss,
  // and no duplicate from concurrent devices / rapid-fire triggers.

  static bool _engagedInFlight = false;

  /// True once `sdk.start()` has succeeded in this process.
  static bool _started = false;

  /// True once the server has the send confirmed — no more RPCs this process.
  static bool _engagedDone = false;

  /// How long to wait for AppsFlyer to acknowledge the event. A timeout does
  /// not cancel the native request, so a late success after it can mean one
  /// extra retry — rare, and preferable to a session stuck forever.
  static const Duration _engagedAckTimeout = Duration(seconds: 30);

  /// Cheap to call from anywhere (after a message, after a friendship is
  /// confirmed, at boot). Never throws, never blocks the caller. Silently does
  /// nothing until the SDK has started: the check is re-run the moment it does
  /// (see the session-ready listener), so an early call is never lost.
  static void checkEngaged() {
    if (_engagedDone || !_started || !isSupported || !isSupabaseReady) return;
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) return;
    unawaited(
      runEngagedCheck(
        claim: () async => (await client.rpc('claim_engaged_user')) == true,
        // Waits for the SDK's native acknowledgement; throws if it fails.
        send: () => AppsFlyerSdk.instance
            .logEvent('engaged_user', awaitResponse: true)
            .timeout(_engagedAckTimeout),
        confirm: () async {
          await client.rpc('confirm_engaged_user_sent');
        },
      ),
    );
  }

  /// The claim → send → confirm sequence, with its collaborators injected so it
  /// can be tested. A single in-flight run at a time absorbs bursts of triggers
  /// on this device; the server lease covers other devices.
  ///
  /// The server is only told "sent" AFTER [send] completes successfully. If
  /// [send] throws, nothing is confirmed: the 10-minute lease expires and the
  /// next trigger (any message, friendship, or app foreground) retries.
  /// Returns true when the event was sent AND confirmed.
  @visibleForTesting
  static Future<bool> runEngagedCheck({
    required Future<bool> Function() claim,
    required Future<void> Function() send,
    required Future<void> Function() confirm,
  }) async {
    if (_engagedInFlight) return false;
    _engagedInFlight = true;
    try {
      if (!await claim()) return false;
      try {
        await send();
      } catch (e) {
        debugPrint('Attribution: engaged_user send failed, will retry: $e');
        return false;
      }
      try {
        await confirm();
        _engagedDone = true;
        return true;
      } catch (e) {
        // Event is out but unconfirmed: the lease expires and a later trigger
        // may re-send once — a rare extra count beats losing the conversion.
        debugPrint('Attribution: engaged confirm failed: $e');
        return false;
      }
    } catch (e) {
      debugPrint('Attribution: engaged check failed: $e');
      return false;
    } finally {
      _engagedInFlight = false;
    }
  }

  /// Test hook: forget the per-process "already confirmed" memory.
  @visibleForTesting
  static void resetEngagedForTest() {
    _engagedInFlight = false;
    _engagedDone = false;
  }
}
