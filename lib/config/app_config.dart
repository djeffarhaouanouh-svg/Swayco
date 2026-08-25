import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;

import 'token_api_resolve_io.dart' if (dart.library.html) 'token_api_resolve_web.dart'
    as resolve;

/// All configuration comes from --dart-define at build time. The [key]
/// parameter is kept for symmetry / future re-introduction of a runtime
/// .env loader.
String _envOrDefine(String key, String defineValue) => defineValue;

// Production fallbacks, baked in so a build launched WITHOUT the
// `--dart-define` flags still ships a working app instead of a dead login
// screen. Google Play pulled the app for "elements d'UI non reactifs" on
// exactly that: the uploaded AAB carried no defines at all (verified by
// grepping libapp.so), so Supabase was never initialised, `Sign in` threw
// `Supabase non configure`, and TOKEN_API_BASE fell back to the emulator
// loopback `http://10.0.2.2:8787`. iOS was fine because its IPA is built by
// .github/workflows/ios-release.yml, which does pass every define.
//
// These are PUBLIC client credentials (already committed in
// build-release.ps1 / dart_defines.env), never secrets. `--dart-define`
// still wins whenever it is passed.
const _kDefaultSupabaseUrl = 'https://rhxenzcdnfvpgjjefztx.supabase.co';
const _kDefaultSupabasePublishableKey =
    'sb_publishable_5NZJowDX1ba6cGwuzFN08Q_j9GxFMXi';
const _kDefaultTokenApiBase = 'https://www.swayco.fr';
const _kDefaultGoogleWebClientId =
    '361554699132-vjspl0l68h93fg9vateiinb1ndboj4ge.apps.googleusercontent.com';
const _kDefaultGoogleIosClientId =
    '361554699132-7864a6b9g008r6do0gekdh4ddftcul48.apps.googleusercontent.com';

/// Base URL of the token server (no trailing slash). Override at compile time
/// via `--dart-define=TOKEN_API_BASE=...` or at runtime via the `.env` file.
String resolvedTokenApiBase() {
  final v = _envOrDefine(
      'TOKEN_API_BASE', const String.fromEnvironment('TOKEN_API_BASE'));
  if (v.isNotEmpty) return v;
  // Only a debug build may fall back to the local dev server; a release
  // build that reached the loopback address is a shipped-dead app.
  if (kDebugMode) return resolve.defaultTokenApiBase();
  return _kDefaultTokenApiBase;
}

/// Shown in the UI (same-origin web after Docker deploy uses [Uri.base.origin]).
String displayTokenApiBase() {
  final v = _envOrDefine(
      'TOKEN_API_BASE', const String.fromEnvironment('TOKEN_API_BASE'));
  if (v.isNotEmpty) return v;
  if (kIsWeb) return Uri.base.removeFragment().origin;
  return resolvedTokenApiBase();
}

/// Supabase project URL. Read from --dart-define then from `.env`.
/// Empty when unset → Supabase init is skipped (the rest of the app works fine).
String resolvedSupabaseUrl() => _envOrDefine(
    'SUPABASE_URL',
    const String.fromEnvironment('SUPABASE_URL',
        defaultValue: _kDefaultSupabaseUrl));

/// Supabase publishable / anon key. Safe to ship to clients.
String resolvedSupabasePublishableKey() => _envOrDefine(
    'SUPABASE_PUBLISHABLE_KEY',
    const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY',
        defaultValue: _kDefaultSupabasePublishableKey));

/// Google OAuth **Web** client ID (`xxxx.apps.googleusercontent.com`). Used as
/// `serverClientId` for the native sign-in flow and verified by Supabase. This
/// is the client whose ID + secret you paste into Supabase → Auth → Providers →
/// Google. Empty when unset → the Google button shows a "not configured" error.
String resolvedGoogleWebClientId() => _envOrDefine(
    'GOOGLE_WEB_CLIENT_ID',
    const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID',
        defaultValue: _kDefaultGoogleWebClientId));

/// Google OAuth **iOS** client ID (`xxxx.apps.googleusercontent.com`). Used as
/// `clientId` on iOS so the native Google SDK can open the consent sheet and
/// return through the reversed-client-id URL scheme declared in Info.plist.
/// Leave empty on Android (the SHA-1-registered Android client is implicit).
String resolvedGoogleIosClientId() => _envOrDefine(
    'GOOGLE_IOS_CLIENT_ID',
    const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID',
        defaultValue: _kDefaultGoogleIosClientId));
