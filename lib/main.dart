import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
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
import 'services/notification_client.dart';
import 'services/profile_api.dart';
import 'services/supabase_service.dart';
import 'services/user_prefs.dart';
import 'theme/whatsapp_call_theme.dart';
import 'translation/openai_realtime_translation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Supabase keys come from --dart-define at build time (Railway / IDE
  // launch.json). No .env loading on the deployed web build.
  await initSupabase();
  // Native push (FCM). Best-effort: a missing google-services.json /
  // GoogleService-Info.plist on dev builds shouldn't crash the app —
  // just skip Firebase init and the notification_client_io will fail
  // its registration silently.
  if (!kIsWeb) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      debugPrint('Firebase init failed: $e');
    }
  }
  // Analytics for the admin dashboard. Starts the batched flush loop and
  // records one `app_open` per launch — the basis for retention (D1/D7/
  // D30) and recurring-user counts.
  Analytics.start();
  Analytics.track('app_open', props: {
    'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
  });
  runApp(const LiveKitTranslateApp());
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
  late final OpenAiRealtimeTranslation _translation;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    _translation = OpenAiRealtimeTranslation();
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
    _translation.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // A guest-invite deep link (`/c/<room>` on web) bypasses login entirely:
    // the visitor joins the call with no account. Detected before anything
    // else so an auth check never gates them.
    final invite = GuestInviteApi.fromCurrentUrl();
    if (invite != null) {
      if (!mounted) return;
      setState(() {
        _guestInvite = invite;
        _loading = false;
      });
      return;
    }
    // Restore the UI language from local prefs as early as possible so the
    // login screen renders in whatever the user picked last time on this
    // device (no-op for a fresh install — falls back to the default).
    final localProfile = await UserPrefs.loadProfile();
    if (localProfile != null && localProfile.sourceLang.isNotEmpty) {
      AppStrings.setFromCode(localProfile.sourceLang);
    }
    final authed = AuthService.isAuthenticated;
    var needsOnboarding = false;
    if (authed) {
      needsOnboarding = await _resolveNeedsOnboarding();
      if (!needsOnboarding) {
        await _hydrateAuthedSession();
      }
    }
    if (!mounted) return;
    setState(() {
      _authed = authed;
      _needsOnboarding = needsOnboarding;
      _loading = false;
    });
  }

  /// Called whenever a fresh sign-in happens (login or signup confirmation).
  /// Brand-new accounts have no `profiles` row yet — that's how we know to
  /// route them through onboarding before the main shell.
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

  /// True when this auth user has never completed onboarding — detected by
  /// the absence of a `profiles` row (or one with no display name) on
  /// Supabase. This is the source of truth so a returning user signing in
  /// on a fresh device skips onboarding even though local prefs are empty.
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
  /// locally-stored onboarding data (display name + spoken language) up to
  /// the Supabase `profiles` row, then start the unread-count listener.
  Future<void> _hydrateAuthedSession() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    final profile = await UserPrefs.loadProfile();
    if (profile != null && profile.firstName.isNotEmpty) {
      await ProfileApi.upsertMyProfile(
        deviceId: uid,
        displayName: profile.firstName,
        language: profile.sourceLang,
      );
    }
    unawaited(ChatUnread.start(uid));
    // Apply the user's saved Settings preferences.
    final prefs = await SharedPreferences.getInstance();
    // In-app sounds: gate the CallAlert ring / dial tone.
    CallAlert.soundsEnabled =
        prefs.getBool(AppSettings.kInAppSounds) ?? true;
    // Push: only register the transport target when the user hasn't
    // turned push off in Settings. No-op on platforms where the
    // notification client is a stub (web, or native before FCM is wired).
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
          title: 'Calls',
          debugShowCheckedModeBanner: false,
          theme: WhatsAppCallTheme.material(),
          home: _buildHome(),
        );
      },
    );
  }

  Widget _buildHome() {
    if (_loading) {
      return const Scaffold(
        backgroundColor: WhatsAppCallTheme.scaffold,
        body: Center(
          child: CircularProgressIndicator(color: WhatsAppCallTheme.accent),
        ),
      );
    }
    // Guest-invite link → straight to the join screen, no login.
    if (_guestInvite != null) {
      return GuestJoinScreen(
        invite: _guestInvite!,
        translation: _translation,
      );
    }
    // Login first. Onboarding only runs for brand-new accounts (no Supabase
    // profile row) — returning users go straight to the shell.
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
    return RootShell(translation: _translation);
  }
}
