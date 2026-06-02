import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import 'supabase_service.dart';

/// Thin wrapper around `Supabase.instance.client.auth` so the rest of the app
/// imports a stable surface instead of reaching into the SDK directly. Every
/// method short-circuits with a clear error when Supabase wasn't configured
/// at build time.
abstract final class AuthService {
  static GoTrueClient get _auth => Supabase.instance.client.auth;

  static User? get currentUser =>
      isSupabaseReady ? _auth.currentUser : null;

  /// Empty string when not authenticated. Use [isAuthenticated] to gate flows.
  static String get currentUserId => currentUser?.id ?? '';

  /// Email tied to the auth account. Lives only on `auth.users` (never copied
  /// to `profiles`), so other users cannot read it.
  static String get currentEmail => currentUser?.email ?? '';

  static bool get isAuthenticated => currentUser != null;

  /// Best-effort first name pulled from the OAuth identity metadata, used to
  /// prefill the onboarding name field on a brand-new social sign-in. Google
  /// populates `full_name` / `name` / `given_name`; Apple only hands the name
  /// over once, which [signInWithApple] mirrors into `given_name` / `full_name`.
  /// Returns the given name when available, otherwise the first token of the
  /// full name. Empty when nothing usable is present.
  static String get suggestedFirstName {
    final meta = currentUser?.userMetadata;
    if (meta == null) return '';
    String pick(String key) => (meta[key]?.toString() ?? '').trim();
    final given = pick('given_name');
    if (given.isNotEmpty) return given;
    final full = pick('full_name').isNotEmpty ? pick('full_name') : pick('name');
    if (full.isEmpty) return '';
    return full.split(RegExp(r'\s+')).first;
  }

  /// Broadcast stream — useful for routing the app between Login / Onboarding
  /// / Home in reaction to sign-in or sign-out.
  static Stream<AuthState> get onAuthStateChange => _auth.onAuthStateChange;

  static Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    return _auth.signUp(email: email.trim().toLowerCase(), password: password);
  }

  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    return _auth.signInWithPassword(
      email: email.trim().toLowerCase(),
      password: password,
    );
  }

  static Future<void> signOut() {
    if (!isSupabaseReady) return Future.value();
    return _auth.signOut();
  }

  static Future<void> resetPassword(String email) {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    return _auth.resetPasswordForEmail(email.trim().toLowerCase());
  }

  /// Re-trigger the signup confirmation email for users who never clicked
  /// the original link. Idempotent server-side: Supabase rate-limits how
  /// often this can fire per address.
  static Future<void> resendSignupConfirmation(String email) {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    return _auth.resend(
      type: OtpType.signup,
      email: email.trim().toLowerCase(),
    );
  }

  // ─── Social sign-in (native flows) ─────────────────────────────────────────
  // Both providers use the *native* path: the platform SDK obtains a signed
  // `idToken`, which we hand to Supabase via `signInWithIdToken`. No external
  // browser, no deep-link round-trip. The `onAuthStateChange` stream above then
  // routes the app to onboarding / home automatically (see main.dart).

  /// Tracks whether `GoogleSignIn.instance.initialize` has run. v7 made
  /// `initialize` a required, one-time async step that must complete before
  /// `authenticate()`; calling it twice is harmless but wasteful.
  static bool _googleInitialized = false;

  /// Native Google sign-in. Throws [StateError] when Supabase or the Google
  /// client IDs weren't configured at build time, and [AuthException] when
  /// Google returns no ID token. Returns `null` if the user cancels the sheet.
  static Future<AuthResponse?> signInWithGoogle() async {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    final webClientId = resolvedGoogleWebClientId();
    final iosClientId = resolvedGoogleIosClientId();
    if (webClientId.isEmpty) {
      throw StateError(
        'GOOGLE_WEB_CLIENT_ID manquant — passe-le via --dart-define.',
      );
    }

    final google = GoogleSignIn.instance;
    if (!_googleInitialized) {
      await google.initialize(
        // serverClientId is the Web client; Supabase validates tokens against
        // it. clientId is the iOS client (ignored on Android, where the
        // SHA-1-registered client is matched implicitly).
        serverClientId: webClientId,
        clientId: iosClientId.isEmpty ? null : iosClientId,
      );
      _googleInitialized = true;
    }

    final GoogleSignInAccount account;
    try {
      account = await google.authenticate(scopeHint: ['email', 'profile']);
    } on GoogleSignInException catch (e) {
      // User dismissed the sheet — treat as a no-op, not an error.
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Aucun ID token renvoyé par Google.');
    }

    return _auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
  }

  /// Native "Sign in with Apple". Only available on iOS / macOS (and the web
  /// fallback). Uses the hashed-nonce handshake Apple requires: the SHA-256 of
  /// a raw nonce is sent to Apple, and the *raw* nonce is replayed to Supabase
  /// so it can verify the token wasn't replayed. Returns `null` on user cancel.
  static Future<AuthResponse?> signInWithApple() async {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }

    final rawNonce = _auth.generateRawNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }

    final idToken = credential.identityToken;
    if (idToken == null) {
      throw const AuthException('Aucun ID token renvoyé par Apple.');
    }

    final response = await _auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );

    // Apple hands over the user's name ONLY on the very first authorization.
    // Persist it onto the auth user so onboarding can prefill the first name.
    final given = credential.givenName?.trim() ?? '';
    final family = credential.familyName?.trim() ?? '';
    if (given.isNotEmpty || family.isNotEmpty) {
      final fullName = [given, family].where((p) => p.isNotEmpty).join(' ');
      try {
        await _auth.updateUser(
          UserAttributes(data: {
            'full_name': fullName,
            if (given.isNotEmpty) 'given_name': given,
            if (family.isNotEmpty) 'family_name': family,
          }),
        );
      } catch (_) {
        // Non-fatal: the session is already valid; a failed metadata write
        // just means onboarding won't have a prefilled name.
      }
    }

    return response;
  }
}
