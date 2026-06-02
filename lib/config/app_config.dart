import 'package:flutter/foundation.dart' show kIsWeb;

import 'token_api_resolve_io.dart' if (dart.library.html) 'token_api_resolve_web.dart'
    as resolve;

/// All configuration comes from --dart-define at build time. The [key]
/// parameter is kept for symmetry / future re-introduction of a runtime
/// .env loader.
String _envOrDefine(String key, String defineValue) => defineValue;

/// Base URL of the token server (no trailing slash). Override at compile time
/// via `--dart-define=TOKEN_API_BASE=...` or at runtime via the `.env` file.
String resolvedTokenApiBase() {
  final v = _envOrDefine(
      'TOKEN_API_BASE', const String.fromEnvironment('TOKEN_API_BASE'));
  if (v.isNotEmpty) return v;
  return resolve.defaultTokenApiBase();
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
    'SUPABASE_URL', const String.fromEnvironment('SUPABASE_URL'));

/// Supabase publishable / anon key. Safe to ship to clients.
String resolvedSupabasePublishableKey() => _envOrDefine(
    'SUPABASE_PUBLISHABLE_KEY',
    const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'));

/// Google OAuth **Web** client ID (`xxxx.apps.googleusercontent.com`). Used as
/// `serverClientId` for the native sign-in flow and verified by Supabase. This
/// is the client whose ID + secret you paste into Supabase → Auth → Providers →
/// Google. Empty when unset → the Google button shows a "not configured" error.
String resolvedGoogleWebClientId() => _envOrDefine(
    'GOOGLE_WEB_CLIENT_ID',
    const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'));

/// Google OAuth **iOS** client ID (`xxxx.apps.googleusercontent.com`). Used as
/// `clientId` on iOS so the native Google SDK can open the consent sheet and
/// return through the reversed-client-id URL scheme declared in Info.plist.
/// Leave empty on Android (the SHA-1-registered Android client is implicit).
String resolvedGoogleIosClientId() => _envOrDefine(
    'GOOGLE_IOS_CLIENT_ID',
    const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'));
