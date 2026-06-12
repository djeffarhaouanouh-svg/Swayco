import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show LiquidGlassWidgets;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'firebase_options.dart';
import 'screens/guest_join_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/root_shell.dart';
import 'services/analytics.dart';
import 'services/app_settings.dart';
import 'services/remote_config.dart';
import 'services/app_strings.dart';
import 'services/app_boot.dart';
import 'services/auth_service.dart';
import 'services/call_alert.dart';
import 'services/chat_unread.dart';
import 'services/app_navigator.dart';
import 'services/guest_invite_api.dart';
import 'services/local_notifications.dart';
import 'services/notification_client.dart';
import 'services/presence_service.dart';
import 'services/profile_api.dart';
import 'services/revenue_cat.dart';
import 'services/supabase_service.dart';
import 'services/user_prefs.dart';
import 'theme/swayco_theme.dart';
// TEST: Grok (xAI) chunk-based translation, swapped in at _getTranslation().
// The OpenAI pipeline file (openai_realtime_translation.dart) is left intact;
// `git revert` restores its import + usage here.
import 'translation/grok_chunk_translation.dart';
import 'translation/realtime_translation_port.dart';
import 'widgets/splash_screen_animation.dart';

/// Runs in a dedicated background isolate when a data push lands while the
/// app is backgrounded or killed. For an incoming call it rings a
/// full-screen, ongoing notification (WhatsApp-style). Other event types
/// carry a `notification` block and are shown by the OS automatically, so
/// there's nothing to do for them here.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  final data = message.data;
  if (data['type'] != 'incoming_call') return;
  final title = (data['title'] ?? data['callerName'] ?? '').toString().trim();
  final body = (data['body'] ?? '').toString().trim();
  await LocalNotifications.showIncomingCall(
    title: title.isEmpty ? 'Appel entrant' : title,
    body: body.isEmpty ? null : body,
  );
}

/// Foreground push: the OS suppresses the tray banner while the app is
/// open, so present it ourselves. Incoming calls are already surfaced by
/// the in-app dialog (see RootShell), so they're skipped here.
void _handleForegroundMessage(RemoteMessage message) {
  final data = message.data;
  if (data['type'] == 'incoming_call') return;
  final n = message.notification;
  final title = (n?.title ?? data['title'] ?? '').toString().trim();
  final body = (n?.body ?? data['body'] ?? '').toString().trim();
  if (title.isEmpty) return;
  unawaited(LocalNotifications.showMessage(
    id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
    title: title,
    body: body.isEmpty ? null : body,
  ));
}

Future<void> main() async {
  // Wrap the whole boot in runZonedGuarded + FlutterError.onError so a
  // silent Release-mode throw never ends up as a blank screen with
  // nothing in the device logs. Every error path debugPrint's the
  // exception — it's the only thing we have left after the 6.1.2+17
  // bisect proved the boot path is otherwise clean.
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      debugPrint('FlutterError: ${details.exception}');
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (e, s) {
      debugPrint('PlatformDispatcher error: $e');
      return true;
    };
    // Supabase keys come from --dart-define at build time. 15s cap so a
    // reviewer device on a bad network still boots — the earlier 5s cap
    // was actively harmful (it cut Hive session recovery mid-flight and
    // left the singleton with an uninitialised `client`).
    try {
      await initSupabase().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('Supabase init slow/failed: $e');
    }
    // Remote config (kill-switches / tunables like the online badge) —
    // best-effort, non-blocking; widgets rebuild via RemoteConfig.version.
    unawaited(RemoteConfig.load());
    // Native push (FCM). Best-effort — a missing google-services on a
    // dev build shouldn't crash the app.
    if (!kIsWeb) {
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(const Duration(seconds: 5));
        // WhatsApp-style incoming calls + chat banners. The background
        // isolate handler rings full-screen on a data-only call push even
        // when the app is killed; foreground pushes are shown inline (the
        // OS suppresses the tray banner while the app is open).
        FirebaseMessaging.onBackgroundMessage(
          _firebaseMessagingBackgroundHandler,
        );
        FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      } catch (e) {
        debugPrint('Firebase init slow/failed: $e');
      }
    }
    // RevenueCat (in-app subscriptions on iOS/Android). No-op on web, which
    // keeps the Stripe checkout. Best-effort — a store hiccup mustn't gate boot.
    try {
      await RevenueCat.init().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('RevenueCat init slow/failed: $e');
    }
    // Seed the hide-online cache so presence renders are correct on
    // the first frame. 2s cap — SharedPreferences must never block.
    try {
      await AppSettings.hydrate().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('AppSettings hydrate slow/failed: $e');
    }
    // Analytics for the admin dashboard. Wrapped because a flaky
    // PlatformDispatcher.locale read on a niche device shouldn't gate
    // runApp.
    try {
      Analytics.start();
      Analytics.track('app_open', props: {
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
    } catch (e) {
      debugPrint('Analytics start failed: $e');
    }
    if (kIsWeb) {
      // Web stays EXACTLY as before — no Liquid Glass wrap, no shader
      // pre-warm. The whole redesign is native-only (iPhone build).
      runApp(const LiveKitTranslateApp());
    } else {
      // Native (iOS/Android): pre-warm the Liquid Glass shaders so the first
      // glass surface doesn't flash white, then wrap the app.
      // respectSystemAccessibility honours iOS "Reduce Transparency / Motion";
      // adaptiveQuality caps shader quality on slow hardware.
      try {
        await LiquidGlassWidgets.initialize()
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('LiquidGlass init slow/failed: $e');
      }
      runApp(
        LiquidGlassWidgets.wrap(
          child: const LiveKitTranslateApp(),
          respectSystemAccessibility: true,
          adaptiveQuality: true,
        ),
      );
    }
  }, (e, s) {
    debugPrint('Uncaught zone error: $e\n$s');
  });
}

class LiveKitTranslateApp extends StatefulWidget {
  const LiveKitTranslateApp({super.key});

  @override
  State<LiveKitTranslateApp> createState() => _LiveKitTranslateAppState();
}

class _LiveKitTranslateAppState extends State<LiveKitTranslateApp> {
  bool _loading = true;
  bool _needsOnboarding = false;
  bool _authed = false;
  /// Set when the app was opened via a guest-invite link (`/c/<room>` on
  /// web). Non-null → skip login entirely and show [GuestJoinScreen].
  GuestInvite? _guestInvite;
  /// Lazy — constructed on first access via [_getTranslation], so
  /// `livekit_client` and `flutter_webrtc` Dart-side warm-up is
  /// deferred until the user actually navigates to a call.
  // TEST: was `OpenAiRealtimeTranslation` — swapped for the Grok chunk pipeline.
  // Revert this field + _getTranslation() to OpenAiRealtimeTranslation to restore.
  RealtimeTranslationPort? _translation;
  RealtimeTranslationPort _getTranslation() {
    return _translation ??= GrokChunkTranslation();
  }
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // React to sign-in / sign-out events anywhere in the app.
    if (isSupabaseReady) {
      _authSub = AuthService.onAuthStateChange.listen((state) {
        final wasAuthed = _authed;
        final nowAuthed = AuthService.isAuthenticated;
        if (wasAuthed != nowAuthed) {
          if (nowAuthed) {
            _onSignedIn();
          } else {
            _onSignedOut();
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    // Only dispose if we actually constructed it — accessing the field
    // via the lazy getter here would force a useless construction. The port
    // is an interface; both concrete impls are ChangeNotifiers.
    final ChangeNotifier? t = _translation as ChangeNotifier?;
    t?.dispose();
    super.dispose();
  }

  /// Runs once at startup. EVERY step that touches a plugin / network
  /// is wrapped — the iOS plugin-channel cascade in 6.1.2+15 proved
  /// that an uncaught `SharedPreferences.getInstance()` throw would
  /// otherwise leave [_loading] true forever and the user staring at
  /// a near-black loading scaffold. The final `setState` flipping
  /// [_loading] off lives in a `finally` so the app boots to the
  /// login screen even when half the plugins are broken.
  Future<void> _bootstrap() async {
    var authed = false;
    var needsOnboarding = false;
    try {
      debugPrint('bootstrap: start');
      // A guest-invite deep link (`/c/<room>` on web) bypasses login
      // entirely: the visitor joins the call with no account. Detected
      // before anything else so an auth check never gates them.
      // Bounded: a never-returning resolver must not trap the boot splash.
      final invite = await GuestInviteApi.resolveFromCurrentUrl()
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (invite != null) {
        if (!mounted) return;
        setState(() {
          _guestInvite = invite;
          _loading = false;
        });
        return;
      }
      // Referral pickup: when the app is opened from
      // `https://www.swayco.fr/?ref=<code>`, stash the code in prefs so we
      // can credit the referrer once this visitor has finished sign-up
      // + onboarding. Cleared by `_maybeAttributePendingReferral`. (Host-
      // agnostic — reads the `ref` query param whatever the host.)
      if (kIsWeb) {
        final ref = Uri.base.queryParameters['ref']?.trim() ?? '';
        if (ref.isNotEmpty) {
          try {
            await UserPrefs.writePendingReferralCode(ref);
          } catch (e) {
            debugPrint('writePendingReferralCode failed: $e');
          }
        }
      }
      // Restore the UI language from local prefs so the login screen
      // renders in whatever the user picked last time on this device
      // (no-op for a fresh install — falls back to the default).
      try {
        final localProfile = await UserPrefs.loadProfile()
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (localProfile != null && localProfile.sourceLang.isNotEmpty) {
          AppStrings.setFromCode(localProfile.sourceLang);
        }
      } catch (e) {
        debugPrint('loadProfile failed: $e');
      }
      authed = AuthService.isAuthenticated;
      debugPrint('bootstrap: authed=$authed');
      if (authed) {
        // Bound the whole authed-state load: any Supabase call inside that
        // never returns (a true hang, which try/catch can't catch) would
        // otherwise leave _loading true forever → user stuck on the splash.
        await (() async {
          needsOnboarding = await _resolveNeedsOnboarding();
          debugPrint('bootstrap: needsOnboarding=$needsOnboarding');
          if (!needsOnboarding) {
            await _hydrateAuthedSession();
          }
        })().timeout(const Duration(seconds: 8), onTimeout: () {
          debugPrint('bootstrap: authed-state load timed out — entering app');
        });
      }
      debugPrint('bootstrap: done');
    } catch (e, s) {
      debugPrint('bootstrap failed: $e\n$s');
    } finally {
      debugPrint('bootstrap: finally → _loading=false');
      if (mounted) {
        setState(() {
          _authed = authed;
          _needsOnboarding = needsOnboarding;
          _loading = false;
        });
        // Only the authed RootShell waits on heavy landing content (the
        // Discover feed reports readiness itself via AppBoot). Guest join,
        // login and onboarding have nothing to load → ready immediately.
        final showsRootShell =
            _guestInvite == null && authed && !needsOnboarding;
        if (!showsRootShell) AppBoot.markHomeReady();
      }
    }
  }

  /// Called whenever a fresh sign-in happens (login or signup
  /// confirmation). Brand-new accounts have no `profiles` row yet —
  /// that's how we know to route them through onboarding before the
  /// main shell.
  Future<void> _onSignedIn() async {
    setState(() => _loading = true);
    var needsOnboarding = false;
    try {
      await (() async {
        needsOnboarding = await _resolveNeedsOnboarding();
        if (!needsOnboarding) {
          await _hydrateAuthedSession();
        }
      })().timeout(const Duration(seconds: 8), onTimeout: () {
        debugPrint('_onSignedIn: authed-state load timed out');
      });
    } catch (e, s) {
      debugPrint('_onSignedIn failed: $e\n$s');
    }
    if (!mounted) return;
    setState(() {
      _authed = true;
      _needsOnboarding = needsOnboarding;
      _loading = false;
    });
  }

  void _onSignedOut() {
    setState(() {
      _authed = false;
      _needsOnboarding = false;
    });
    // Detach from RevenueCat so the next user starts on a clean store id.
    unawaited(RevenueCat.logOut());
  }

  /// Consume the pending `?ref=<code>` captured at boot (if any) and
  /// call the `attribute_referral` RPC so the referrer gets credit for
  /// this new sign-up. Cleared regardless of outcome — bad codes /
  /// self-refs shouldn't get retried forever on subsequent launches.
  Future<void> _maybeAttributePendingReferral() async {
    final code = await UserPrefs.readPendingReferralCode();
    if (code.isEmpty) return;
    try {
      await ProfileApi.attributeReferral(code);
    } catch (e) {
      debugPrint('attributeReferral failed: $e');
    } finally {
      await UserPrefs.clearPendingReferralCode();
    }
  }

  /// True when this auth user has never completed onboarding — detected
  /// by the absence of a `profiles` row (or one with no display name)
  /// on Supabase. This is the source of truth so a returning user
  /// signing in on a fresh device skips onboarding even though local
  /// prefs are empty.
  Future<bool> _resolveNeedsOnboarding() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return false;
    if (!isSupabaseReady) return false;
    try {
      final remote = await ProfileApi.fetchById(uid);
      return remote == null || remote.displayName.trim().isEmpty;
    } catch (_) {
      // On network failure, don't trap a returning user in onboarding —
      // assume they're set up and let them retry from the profile tab.
      return false;
    }
  }

  /// Side-effects that depend on having a current auth user: mirror the
  /// locally-stored onboarding data (display name + spoken language) up
  /// to the Supabase `profiles` row, then start the unread-count
  /// listener.
  Future<void> _hydrateAuthedSession() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    // Tie store purchases to this account (no-op on web / unconfigured).
    unawaited(RevenueCat.identify(uid));
    final profile = await UserPrefs.loadProfile();
    // The ACCOUNT (remote profile) is the source of truth for the interface
    // language: a change made on another device / the web syncs DOWN here
    // instead of this device's stale local cache clobbering it. Fetch it once
    // and reuse it for the language sync AND the returning-user path.
    RemoteProfile? remote;
    var remoteOk = false;
    try {
      remote = await ProfileApi.fetchById(uid);
      remoteOk = true;
    } catch (e) {
      debugPrint('hydrate fetch remote profile failed: $e');
    }
    final remoteLang = remote?.language.trim() ?? '';

    if (profile != null && profile.firstName.isNotEmpty) {
      // Prefer the account's language; fall back to the local pick only when
      // the account genuinely has none yet (read OK + empty).
      final lang = remoteLang.isNotEmpty ? remoteLang : profile.sourceLang;
      if (lang.trim().isNotEmpty) {
        AppStrings.setFromCode(lang);
        // Keep the local cache in step so the next cold boot restores in the
        // account's language immediately (no stale-language flash).
        if (lang != profile.sourceLang) {
          await UserPrefs.setSourceLang(lang);
        }
      }
      // Only publish UP when we have a trustworthy read of the account. Two
      // devices can share one account, so a flaky read on THIS device must
      // never clobber the language the OTHER device just set — skip the write
      // rather than risk pushing this device's stale cache.
      if (remoteOk) {
        await ProfileApi.upsertMyProfile(
          deviceId: uid,
          displayName: profile.firstName,
          language: lang,
          gender: profile.gender,
        );
      }
    } else if (remote != null) {
      // Returning user on a fresh device / freshly-installed app: local prefs
      // are empty but the account holds their name + language. Apply it and
      // cache everything so the next cold boot restores instantly.
      if (remoteLang.isNotEmpty) AppStrings.setFromCode(remoteLang);
      if (remote.displayName.trim().isNotEmpty) {
        await UserPrefs.completeOnboarding(
          firstName: remote.displayName,
          sourceLang: remote.language,
          targetLang: '',
          gender: remote.gender,
        );
      }
    }
    // Once the profile row exists, fire the deferred referral
    // attribution captured at boot. Best-effort — failure is silent so
    // a flaky network never blocks the user from entering the app.
    unawaited(_maybeAttributePendingReferral());
    unawaited(ChatUnread.start(uid));
    // Presence heartbeat — keeps profiles.last_seen fresh for the
    // online indicator (gated by each user's hide-online-status
    // setting).
    PresenceService.start(uid);
    // Apply the user's saved Settings preferences.
    final prefs = await SharedPreferences.getInstance();
    // In-app sounds: gate the CallAlert ring / dial tone.
    CallAlert.soundsEnabled =
        prefs.getBool(AppSettings.kInAppSounds) ?? true;
    // Push: only register the transport target when the user hasn't
    // turned push off in Settings. No-op on platforms where the
    // notification client is a stub (web, or native before FCM is
    // wired).
    if (prefs.getBool(AppSettings.kPush) ?? true) {
      // Boot only registers the FCM token when permission is ALREADY granted
      // — it never fires the native prompt cold. A fresh user is asked later,
      // with rationale, via the message-list priming flow ([NotifEnableFlow]),
      // so the one-shot iOS prompt isn't wasted before they understand why.
      unawaited(NotificationClient.registerIfAuthorized(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppStrings.currentBcp47,
      builder: (context, _, _) {
        return MaterialApp(
          title: 'Swayco',
          navigatorKey: rootNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: SC.material(),
          // Honour the device's "Larger Text" setting (good for readability)
          // but cap it at 1.3× so an extreme accessibility font size can never
          // overflow buttons / headers / labels and break the layout.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              // App-wide: tapping anywhere that isn't an interactive widget
              // (button, field, scrollable…) dismisses the keyboard, so no
              // screen can leave it stuck open. translucent = it only catches
              // taps that fall through, never blocks real taps.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: ValueListenableBuilder<bool>(
            valueListenable: AppBoot.homeReady,
            builder: (context, homeReady, _) {
              // Keep the boot splash up until the landing screen is FULLY
              // ready: past bootstrap AND its content loaded (e.g. the Discover
              // feed reports via AppBoot) — so the app appears complete, never
              // as a spinner behind the splash. No artificial minimum.
              final showSplash = _loading || !homeReady;
              return Stack(
                children: [
                  // The real screen is built as soon as bootstrap resolves so
                  // it can load its data *behind* the splash; pure black until
                  // then.
                  Positioned.fill(
                    child: _loading
                        ? const ColoredBox(color: Color(0xFF000000))
                        : _buildHome(),
                  ),
                  // Splash overlay — cross-fades out once everything is ready.
                  Positioned.fill(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 450),
                      child: showSplash
                          ? const SplashScreenAnimation()
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHome() {
    // Guest-invite link → straight to the join screen, no login.
    if (_guestInvite != null) {
      return GuestJoinScreen(
        invite: _guestInvite!,
        translation: _getTranslation(),
      );
    }
    // Login first. Onboarding only runs for brand-new accounts (no
    // Supabase profile row) — returning users go straight to the shell.
    if (!_authed) {
      return const LoginScreen();
    }
    if (_needsOnboarding) {
      return OnboardingScreen(
        onCompleted: () async {
          await _hydrateAuthedSession();
          if (!mounted) return;
          setState(() => _needsOnboarding = false);
        },
      );
    }
    return RootShell(translation: _getTranslation());
  }
}
