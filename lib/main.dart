import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'firebase_options.dart';
import 'screens/guest_join_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/root_shell.dart';
import 'services/analytics.dart';
import 'services/app_settings.dart';
import 'services/app_strings.dart';
import 'services/auth_service.dart';
import 'services/call_alert.dart';
import 'services/chat_unread.dart';
import 'services/guest_invite_api.dart';
import 'services/local_notifications.dart';
import 'services/notification_client.dart';
import 'services/presence_service.dart';
import 'services/profile_api.dart';
import 'services/supabase_service.dart';
import 'services/user_prefs.dart';
import 'theme/swayco_theme.dart';
import 'translation/openai_realtime_translation.dart';
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
    runApp(const LiveKitTranslateApp());
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
  /// Lets the boot splash play its Lottie through ONCE before the first real
  /// screen takes over, even when [_bootstrap] finishes in a few hundred ms.
  /// Flipped by the splash's onComplete callback, with a safety [Timer] in
  /// [initState] in case the animation never loads.
  bool _minSplashElapsed = false;
  /// Set when the app was opened via a guest-invite link (`/c/<room>` on
  /// web). Non-null → skip login entirely and show [GuestJoinScreen].
  GuestInvite? _guestInvite;
  /// Lazy — constructed on first access via [_getTranslation], so
  /// `livekit_client` and `flutter_webrtc` Dart-side warm-up is
  /// deferred until the user actually navigates to a call.
  OpenAiRealtimeTranslation? _translation;
  OpenAiRealtimeTranslation _getTranslation() {
    return _translation ??= OpenAiRealtimeTranslation();
  }
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // Safety net: the splash normally dismisses when its Lottie finishes one
    // play (see _buildHome → onComplete). If the animation never loads (asset
    // error), force the boot splash off after a bounded wait so the app can
    // never get stuck on it.
    Timer(const Duration(milliseconds: 4500), () {
      if (mounted && !_minSplashElapsed) {
        setState(() => _minSplashElapsed = true);
      }
    });
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
    // via the lazy getter here would force a useless construction.
    _translation?.dispose();
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
      // A guest-invite deep link (`/c/<room>` on web) bypasses login
      // entirely: the visitor joins the call with no account. Detected
      // before anything else so an auth check never gates them.
      final invite = await GuestInviteApi.resolveFromCurrentUrl();
      if (invite != null) {
        if (!mounted) return;
        setState(() {
          _guestInvite = invite;
          _loading = false;
        });
        return;
      }
      // Referral pickup: when the app is opened from
      // `https://swayco.fr/?ref=<code>`, stash the code in prefs so we
      // can credit the referrer once this visitor has finished sign-up
      // + onboarding. Cleared by `_maybeAttributePendingReferral`.
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
        final localProfile = await UserPrefs.loadProfile();
        if (localProfile != null && localProfile.sourceLang.isNotEmpty) {
          AppStrings.setFromCode(localProfile.sourceLang);
        }
      } catch (e) {
        debugPrint('loadProfile failed: $e');
      }
      authed = AuthService.isAuthenticated;
      if (authed) {
        needsOnboarding = await _resolveNeedsOnboarding();
        if (!needsOnboarding) {
          await _hydrateAuthedSession();
        }
      }
    } catch (e, s) {
      debugPrint('bootstrap failed: $e\n$s');
    } finally {
      if (mounted) {
        setState(() {
          _authed = authed;
          _needsOnboarding = needsOnboarding;
          _loading = false;
        });
      }
    }
  }

  /// Called whenever a fresh sign-in happens (login or signup
  /// confirmation). Brand-new accounts have no `profiles` row yet —
  /// that's how we know to route them through onboarding before the
  /// main shell.
  Future<void> _onSignedIn() async {
    setState(() => _loading = true);
    final needsOnboarding = await _resolveNeedsOnboarding();
    if (!needsOnboarding) {
      await _hydrateAuthedSession();
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
  /// Pull the Supabase profile's interface language and apply it to
  /// [AppStrings]. Best-effort — a network failure just leaves the
  /// current locale untouched.
  Future<void> _applyRemoteLanguage(String uid) async {
    try {
      final remote = await ProfileApi.fetchById(uid);
      final code = remote?.language.trim() ?? '';
      if (code.isNotEmpty) AppStrings.setFromCode(code);
    } catch (e) {
      debugPrint('applyRemoteLanguage failed: $e');
    }
  }

  Future<void> _hydrateAuthedSession() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    final profile = await UserPrefs.loadProfile();
    if (profile != null && profile.firstName.isNotEmpty) {
      await ProfileApi.upsertMyProfile(
        deviceId: uid,
        displayName: profile.firstName,
        language: profile.sourceLang,
        gender: profile.gender,
      );
      // Local prefs may predate the language picker, or hold an empty
      // source lang — fall back to the Supabase value so the UI still
      // speaks the user's chosen language.
      if (profile.sourceLang.trim().isEmpty) {
        await _applyRemoteLanguage(uid);
      }
    } else {
      // Returning user on a fresh device / freshly-installed app: local
      // prefs are empty but the Supabase profile holds their name +
      // language. The boot-time restore reads ONLY local prefs, so
      // without this the UI stays on the English default even though the
      // account is set to French. Pull the remote profile down, apply its
      // language, and cache it locally so the next cold boot restores
      // instantly with no round-trip.
      try {
        final remote = await ProfileApi.fetchById(uid);
        if (remote != null) {
          if (remote.language.trim().isNotEmpty) {
            AppStrings.setFromCode(remote.language);
          }
          if (remote.displayName.trim().isNotEmpty) {
            await UserPrefs.completeOnboarding(
              firstName: remote.displayName,
              sourceLang: remote.language,
              targetLang: '',
              gender: remote.gender,
            );
          }
        }
      } catch (e) {
        debugPrint('hydrate remote profile/language failed: $e');
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
      unawaited(NotificationClient.register(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppStrings.currentBcp47,
      builder: (context, _, _) {
        return MaterialApp(
          title: 'Swayco',
          debugShowCheckedModeBanner: false,
          theme: SC.material(),
          home: _buildHome(),
        );
      },
    );
  }

  Widget _buildHome() {
    if (_loading || !_minSplashElapsed) {
      // Black splash: the Traduction.json Lottie, played through once. When it
      // finishes (or the safety Timer fires), _minSplashElapsed flips and the
      // first real screen takes over.
      return SplashScreenAnimation(
        onComplete: () {
          if (mounted && !_minSplashElapsed) {
            setState(() => _minSplashElapsed = true);
          }
        },
      );
    }
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
