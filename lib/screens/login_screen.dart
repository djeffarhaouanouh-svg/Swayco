import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';
import 'forgot_password_screen.dart';

/// Welcome screen shown when the user has no Supabase Auth session. Lets them
/// either sign in or create a new account with email + password. After a
/// successful sign-in the parent (`main.dart`) reacts to the auth state
/// change and routes to onboarding / home.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Mode { signIn, signUp }

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _info;

  /// True once we know the entered email exists but isn't confirmed yet â€”
  /// drives the "Resend confirmation email" affordance.
  bool _showResendConfirmation = false;

  static final _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$',
  );

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    setState(() {
      _error = null;
      _info = null;
      _showResendConfirmation = false;
    });
    if (!_emailRegex.hasMatch(email)) {
      setState(() => _error = AppStrings.t('login_err_email'));
      return;
    }
    if (password.length < 6) {
      setState(() => _error = AppStrings.t('login_err_password'));
      return;
    }
    setState(() => _busy = true);
    try {
      if (_mode == _Mode.signUp) {
        final res = await AuthService.signUp(email: email, password: password);
        // Supabase may require email confirmation depending on project config.
        // If session is null, the user has to confirm via email link first.
        if (!mounted) return;
        if (res.session == null) {
          setState(() {
            _info = AppStrings.t('login_check_inbox');
            _showResendConfirmation = true;
            _busy = false;
          });
          return;
        }
      } else {
        await AuthService.signIn(email: email, password: password);
      }
      // Parent listens to auth state changes â€” it'll route us away.
    } on AuthException catch (e) {
      if (!mounted) return;
      // Surface the "Resend confirmation" affordance when the failure is
      // specifically "email not confirmed" so the user has a way forward
      // without retyping everything.
      final code = e.code ?? '';
      final msg = e.message.toLowerCase();
      final notConfirmed =
          code == 'email_not_confirmed' || msg.contains('email not confirmed');
      final invalidCredentials = code == 'invalid_credentials' ||
          msg.contains('invalid login credentials');
      setState(() {
        _error = notConfirmed
            ? AppStrings.t('login_err_not_confirmed')
            : invalidCredentials
                ? AppStrings.t('login_err_invalid_credentials')
                : e.message;
        _showResendConfirmation = notConfirmed;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _resendConfirmation() async {
    final email = _emailCtrl.text.trim();
    if (!_emailRegex.hasMatch(email)) {
      setState(() => _error = AppStrings.t('login_err_email'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await AuthService.resendSignupConfirmation(email);
      if (!mounted) return;
      setState(() {
        _info = AppStrings.t('login_resend_sent');
        _busy = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  void _openForgotPassword() {
    setState(() {
      _error = null;
      _info = null;
      _showResendConfirmation = false;
    });
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ForgotPasswordScreen(initialEmail: _emailCtrl.text.trim()),
      ),
    );
  }

  void _toggleMode() {
    setState(() {
      _mode = _mode == _Mode.signIn ? _Mode.signUp : _Mode.signIn;
      _error = null;
      _info = null;
    });
  }

  /// Apple sign-in is native only on Apple platforms. Hide the button
  /// elsewhere so Android users don't see a dead control.
  bool get _showApple => !kIsWeb && Platform.isIOS;

  Future<void> _signInWithGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _showResendConfirmation = false;
    });
    try {
      final res = await AuthService.signInWithGoogle();
      // Null = user cancelled the sheet; just drop the spinner.
      if (res == null && mounted) setState(() => _busy = false);
      // On success the parent's auth listener routes us away — leave _busy on
      // so the form stays disabled during the transition.
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _signInWithApple() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _showResendConfirmation = false;
    });
    try {
      final res = await AuthService.signInWithApple();
      if (res == null && mounted) setState(() => _busy = false);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSignUp = _mode == _Mode.signUp;
    return Scaffold(
      backgroundColor: SwayOnb.screenBg,
      // No top SafeArea: the hero photo is meant to run under the status bar.
      // The form below re-applies the bottom inset.
      body: SwayHalo(
        preset: SwayHaloPreset.login,
        child: SingleChildScrollView(
        child: Column(
          children: [
            _LoginHero(height: MediaQuery.sizeOf(context).height * 0.30),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Centred under the photo, in the app's display face —
                        // the hero carries the screen now, so the title reads
                        // as its caption rather than a left-aligned form label.
                        Center(
                          child: SwayTitle(
                            isSignUp
                                ? AppStrings.t('login_title_signup')
                                : AppStrings.t('login_title_signin'),
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          isSignUp
                              ? AppStrings.t('login_subtitle_signup')
                              : AppStrings.t('login_subtitle_signin'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: SC.textMuted,
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 26),
                        SwayInput(
                          controller: _emailCtrl,
                          hint: AppStrings.t('login_email_hint'),
                          keyboardType: TextInputType.emailAddress,
                          textCapitalization: TextCapitalization.none,
                          enabled: !_busy,
                        ),
                        const SizedBox(height: 14),
                        SwayInput(
                          controller: _passwordCtrl,
                          hint: AppStrings.t('login_password_label'),
                          obscure: !_showPassword,
                          enabled: !_busy,
                          trailing: IconButton(
                            onPressed: () => setState(
                              () => _showPassword = !_showPassword,
                            ),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: SwayOnb.dim,
                            ),
                          ),
                        ),
                        if (!isSignUp) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _busy ? null : _openForgotPassword,
                              child: Text(AppStrings.t('login_forgot')),
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            style: const TextStyle(
                              color: Color(0xFFFFAB91),
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (_info != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _info!,
                            style: const TextStyle(
                              color: SC.accent,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (_showResendConfirmation) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _busy ? null : _resendConfirmation,
                              icon: const Icon(
                                Icons.mark_email_unread_outlined,
                                size: 18,
                              ),
                              label: Text(AppStrings.t('login_resend_confirm')),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            SwayCta(
                              label: isSignUp
                                  ? AppStrings.t('login_btn_signup')
                                  : AppStrings.t('login_btn_signin'),
                              onPressed: _busy ? null : _submit,
                            ),
                            if (_busy)
                              const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: SwayOnb.onAccent,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              isSignUp
                                  ? AppStrings.t('login_have_account')
                                  : AppStrings.t('login_no_account'),
                              style: const TextStyle(
                                color: SC.textMuted,
                                fontSize: 13,
                              ),
                            ),
                            TextButton(
                              onPressed: _busy ? null : _toggleMode,
                              child: Text(
                                isSignUp
                                    ? AppStrings.t('login_btn_signin')
                                    : AppStrings.t('login_btn_signup'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Expanded(
                              child: Divider(color: SC.glassBorder),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                AppStrings.t('login_or'),
                                style: const TextStyle(
                                  color: SC.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const Expanded(
                              child: Divider(color: SC.glassBorder),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _SocialButton(
                          leading: SvgPicture.asset(
                            'assets/google-logo-search-new-svgrepo-com.svg',
                            width: 22,
                            height: 22,
                          ),
                          label: AppStrings.t('login_continue_google'),
                          onPressed: _busy ? null : _signInWithGoogle,
                        ),
                        if (_showApple) ...[
                          const SizedBox(height: 12),
                          _SocialButton(
                            icon: Icons.apple,
                            label: AppStrings.t('login_continue_apple'),
                            onPressed: _busy ? null : _signInWithApple,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Full-bleed group-selfie header for the login screen. The photo runs under
/// the status bar and fades ITSELF out (dstIn) at the bottom, so the page
/// background shows through with no seam. A short dark scrim at the very top
/// keeps the system status-bar glyphs readable over the bright sky.
class _LoginHero extends StatelessWidget {
  const _LoginHero({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 0.45, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: Image.asset(
              'assets/bienvenue.jpg',
              fit: BoxFit.cover,
              // Faces sit in the upper third of the 1023x1537 source — bias
              // the crop up so they survive a short hero.
              alignment: const Alignment(0, -0.3),
            ),
          ),
          const Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 110,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x59000000), Colors.transparent],
                  ),
                ),
                child: SizedBox(width: double.infinity),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A neutral, full-width "Continue with …" pill matching the Swayco glass DA.
/// Kept provider-agnostic (icon + label) so Google and Apple share one widget.
class _SocialButton extends StatelessWidget {
  const _SocialButton({
    this.icon,
    this.leading,
    required this.label,
    required this.onPressed,
  }) : assert(icon != null || leading != null);

  /// Monochrome icon (e.g. Apple). Ignored when [leading] is provided.
  final IconData? icon;

  /// Custom leading widget — used for the multicolour Google logo, which a
  /// font [IconData] can't render.
  final Widget? leading;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: leading ?? Icon(icon, color: SC.textPrimary, size: 24),
      label: Text(
        label,
        style: const TextStyle(
          color: SC.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: SC.glassBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
