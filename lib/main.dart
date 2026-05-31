import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'services/diag.dart';
import 'services/guest_invite_api.dart';
import 'services/notification_client.dart';
import 'services/presence_service.dart';
import 'services/profile_api.dart';
import 'services/supabase_service.dart';
import 'services/user_prefs.dart';
import 'theme/swayco_theme.dart';
import 'translation/openai_realtime_translation.dart';

Future<void> main() async {
  // Capture every uncaught error path so a Release crash doesn't end up
  // as a silent black screen on a real device. Every channel reports to
  // /diag — together with the boot-step pings below they tell us, from
  // the Railway logs alone, exactly where the app went dark.
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      Diag.error('flutter-error', details.exception,
          details.stack ?? StackTrace.empty);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (e, s) {
      Diag.error('platform-error', e, s);
      return true;
    };
    // Read the real version+build so Diag pings stop reporting the
    // hardcoded string they used to ship with. Awaited because the
    // earliest pings should already carry the correct id — the channel
    // is cheap once the binding is up.
    try {
      await Diag.bind().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Leave the fallback "unknown" in place.
    }
    // First ping AFTER the binding is up so http works.
    unawaited(Diag.ping('main-start'));

    // Supabase keys come from --dart-define at build time. 15s cap so a
    // reviewer device on a bad network still boots. The earlier 5s cap
    // was actively harmful: on first-install iOS Release builds,
    // Supabase.initialize routinely takes 6–10s for Hive session
    // recovery, and cutting the await mid-initialise left the singleton
    // alive but with its late `client` field unset — a downstream
    // initState read of `_auth.onAuthStateChange` then crashed with
    // `LateInitializationError: Field 'client' has not been
    // initialized` (the bug behind the post-splash black screen we
    // were chasing). 15s is well past the normal worst case and still
    // short enough not to register as a hang in App Review.
    try {
      await initSupabase().timeout(const Duration(seconds: 15));
    } catch (e, s) {
      Diag.error('supabase-fail', e, s);
    }
    // Native push (FCM). Best-effort — missing google-services on dev
    // builds shouldn't crash the app.
    if (!kIsWeb) {
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(const Duration(seconds: 5));
      } catch (e, s) {
        Diag.error('firebase-fail', e, s);
      }
    }
    // Seed the hide-online cache so presence renders are correct on
    // the first frame. 2s cap — SharedPreferences must never block.
    try {
      await AppSettings.hydrate().timeout(const Duration(seconds: 2));
    } catch (e, s) {
      Diag.error('hydrate-fail', e, s);
    }
    // Analytics for the admin dashboard. Wrapped because a flaky
    // PlatformDispatcher.locale read on a niche device shouldn't
    // gate runApp.
    try {
      Analytics.start();
      Analytics.track('app_open', props: {
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
    } catch (e, s) {
      Diag.error('analytics-fail', e, s);
    }
    unawaited(Diag.ping('runapp-called'));
    runApp(const LiveKitTranslateApp());
  }, (e, s) {
    Diag.error('zone-fail', e, s);
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
  /// Lazy — constructed on first access via [_getTranslation]. The
  /// point: nobody in the boot path touches it, so `livekit_client` +
  /// `flutter_webrtc` Dart-side warm-up is deferred until the user
  /// actually navigates to a call. If LiveKit/WebRTC is what's hanging
  /// Release builds on real devices, keeping it dormant lets the login
  /// screen render and confirms the diagnosis by elimination.
  /// Key on the RepaintBoundary that wraps _buildHome — used by
  /// [_captureRenderedFrame] to ask the engine for a PNG of exactly the
  /// pixels Flutter shipped to the platform compositor. If the device
  /// shows pure black but the captured PNG shows our LoginScreen, the
  /// bug is downstream of Flutter (something is drawing on top); the
  /// reverse means Flutter itself rendered black.
  final GlobalKey _captureKey = GlobalKey();
  bool _captureDone = false;

  OpenAiRealtimeTranslation? _translation;
  OpenAiRealtimeTranslation _getTranslation() {
    final existing = _translation;
    if (existing != null) return existing;
    Diag.ping('translation-construct');
    final created = OpenAiRealtimeTranslation();
    Diag.ping('translation-constructed');
    _translation = created;
    return created;
  }
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    // Don't construct _translation here — let the lazy `late final`
    // initialiser fire the first time something actually reads it
    // (GuestJoinScreen or RootShell).
    _bootstrap();
    // First post-mount ping — if Railway sees this, the Flutter
    // widget tree did render at least once. We then schedule a delayed
    // capture so the LoginScreen rebuild has time to land.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Diag.ping('first-frame');
    });
    // Capture the actual painted pixels + the widget tree dump 1.5s
    // after mount so any post-bootstrap rebuild (loading → login) has
    // already happened. Uploaded via POST /diag.
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted || _captureDone) return;
      _captureDone = true;
      unawaited(_captureAndUploadFrame());
      unawaited(_uploadWidgetTreeDump());
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
    // Only dispose if we actually ever constructed it — otherwise the
    // null-coalescing here would defeat the whole "stay dormant until
    // needed" diagnosis.
    _translation?.dispose();
    super.dispose();
  }

  /// Snapshot the RepaintBoundary that wraps the home widget and POST
  /// the PNG bytes (base64) to /diag. Tiny pixelRatio because we just
  /// need to see *something* — a colour and rough layout is enough to
  /// distinguish "Flutter rendered black" from "Flutter rendered
  /// LoginScreen and something covered it".
  Future<void> _captureAndUploadFrame() async {
    RenderRepaintBoundary? capturedBoundary;
    try {
      final ctx = _captureKey.currentContext;
      if (ctx == null) {
        unawaited(Diag.ping('capture-no-context'));
        return;
      }
      // Ping the dimensions Flutter THINKS the device has — if this
      // reports 0×0 the FlutterView itself is mis-sized by iOS native,
      // not anything Dart-side.
      try {
        final mq = MediaQuery.of(ctx);
        unawaited(Diag.ping('capture-media-query',
            note: 'w=${mq.size.width.toStringAsFixed(1)} '
                'h=${mq.size.height.toStringAsFixed(1)} '
                'devicePixelRatio=${mq.devicePixelRatio.toStringAsFixed(2)}'));
      } catch (_) {}
      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary) {
        unawaited(Diag.ping('capture-no-boundary'));
        return;
      }
      capturedBoundary = ro;
      unawaited(Diag.ping('capture-boundary-size',
          note: 'w=${ro.size.width.toStringAsFixed(1)} '
              'h=${ro.size.height.toStringAsFixed(1)} '
              'hasSize=${ro.hasSize}'));
      final image = await ro.toImage(pixelRatio: 0.2);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        unawaited(Diag.ping('capture-no-bytes'));
        return;
      }
      final bytes = byteData.buffer.asUint8List();
      final b64 = base64Encode(bytes);
      unawaited(
        Diag.ping(
          'capture-meta',
          note: 'w=${ro.size.width.toStringAsFixed(0)} '
              'h=${ro.size.height.toStringAsFixed(0)} '
              'png_bytes=${bytes.length}',
        ),
      );
      unawaited(Diag.upload('capture-png-b64', b64));
    } catch (e, s) {
      final size = capturedBoundary?.size;
      Diag.error(
        'capture-fail',
        e,
        s,
        note: size == null
            ? 'size=unknown'
            : 'w=${size.width.toStringAsFixed(1)} '
                'h=${size.height.toStringAsFixed(1)}',
      );
    }
  }

  /// Dump the live widget tree (toStringDeep) and POST it. Lets us see
  /// from Railway alone whether LoginScreen is genuinely mounted, what
  /// its layout constraints are, and whether something else is on top.
  Future<void> _uploadWidgetTreeDump() async {
    try {
      final root = WidgetsBinding.instance.rootElement;
      final dump = root?.toStringDeep() ?? '<no root element>';
      unawaited(Diag.upload('tree-dump', dump));
    } catch (e, s) {
      Diag.error('tree-dump-fail', e, s);
    }
  }

  Future<void> _bootstrap() async {
    unawaited(Diag.ping('bootstrap-start'));
    // A guest-invite deep link (`/c/<room>` on web) bypasses login entirely:
    // the visitor joins the call with no account. Detected before anything
    // else so an auth check never gates them.
    final invite = await GuestInviteApi.resolveFromCurrentUrl();
    if (invite != null) {
      if (!mounted) return;
      setState(() {
        _guestInvite = invite;
        _loading = false;
      });
      return;
    }
    // Referral pickup: when the app is opened from `https://swayco.fr/?ref=<code>`
    // (the link a user shared from the profile screen), stash the code in
    // prefs so we can credit the referrer once this visitor has finished
    // sign-up + onboarding. Cleared by `_maybeAttributePendingReferral`.
    if (kIsWeb) {
      final ref = Uri.base.queryParameters['ref']?.trim() ?? '';
      if (ref.isNotEmpty) {
        await UserPrefs.writePendingReferralCode(ref);
      }
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
    Diag.ping('bootstrap-end',
        note: 'authed=$authed onboarding=$needsOnboarding');
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

  /// Consume the pending `?ref=<code>` captured at boot (if any) and call
  /// the `attribute_referral` RPC so the referrer gets credit for this
  /// new sign-up. Cleared regardless of outcome — bad codes / self-refs
  /// shouldn't get retried forever on subsequent launches.
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
        gender: profile.gender,
      );
    }
    // Once the profile row exists, fire the deferred referral attribution
    // captured at boot. Best-effort — failure is silent so a flaky network
    // never blocks the user from entering the app.
    unawaited(_maybeAttributePendingReferral());
    unawaited(ChatUnread.start(uid));
    // Presence heartbeat — keeps profiles.last_seen fresh for the online
    // indicator (gated by each user's hide-online-status setting).
    PresenceService.start(uid);
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
    // BISECT STEP: skip ValueListenableBuilder + SC.material() + the
    // _buildHome tree entirely and render a flat red ColoredBox under
    // a vanilla MaterialApp. Everything BEFORE this — runZonedGuarded,
    // Supabase / Firebase / AppSettings init, LiveKitTranslateApp
    // mounting, _bootstrap, the _captureAndUploadFrame schedule — is
    // unchanged. If the device still shows red, the bug is inside
    // _buildHome / LoginScreen / RepaintBoundary / SC.material() /
    // ValueListenableBuilder. If the device shows black, the bug is
    // earlier — somewhere in main() or in the LiveKitTranslateApp
    // initState / plugin imports.
    unawaited(Diag.ping('bisect-build-red'));
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(color: Color(0xFFFF0000)),
    );
  }

  Widget _buildHome() {
    if (_loading) {
      unawaited(Diag.ping('build-home-loading'));
      return const Scaffold(
        backgroundColor: SC.bg,
        body: Center(
          child: CircularProgressIndicator(color: SC.accent),
        ),
      );
    }
    // Guest-invite link → straight to the join screen, no login.
    if (_guestInvite != null) {
      unawaited(Diag.ping('build-home-guest'));
      return GuestJoinScreen(
        invite: _guestInvite!,
        translation: _getTranslation(),
      );
    }
    // Login first. Onboarding only runs for brand-new accounts (no Supabase
    // profile row) — returning users go straight to the shell.
    if (!_authed) {
      unawaited(Diag.ping('build-home-login'));
      return const LoginScreen();
    }
    if (_needsOnboarding) {
      unawaited(Diag.ping('build-home-onboarding'));
      return OnboardingScreen(
        onCompleted: () async {
          await _hydrateAuthedSession();
          if (!mounted) return;
          setState(() => _needsOnboarding = false);
        },
      );
    }
    unawaited(Diag.ping('build-home-shell'));
    return RootShell(translation: _getTranslation());
  }
}
