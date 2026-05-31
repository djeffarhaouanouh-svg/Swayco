import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/diag.dart';
import '../theme/swayco_theme.dart';

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

  static final _emailRegex =
      RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$');

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
      setState(() {
        _error = notConfirmed
            ? AppStrings.t('login_err_not_confirmed')
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

  Future<void> _forgotPassword() async {
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
      await AuthService.resetPassword(email);
      if (!mounted) return;
      setState(() {
        _info = AppStrings.t('login_reset_sent');
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

  void _toggleMode() {
    setState(() {
      _mode = _mode == _Mode.signIn ? _Mode.signUp : _Mode.signIn;
      _error = null;
      _info = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    unawaited(Diag.ping('login-screen-build'));
    final isSignUp = _mode == _Mode.signUp;
    return Scaffold(
      backgroundColor: SC.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isSignUp
                        ? AppStrings.t('login_title_signup')
                        : AppStrings.t('login_title_signin'),
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isSignUp
                        ? AppStrings.t('login_subtitle_signup')
                        : AppStrings.t('login_subtitle_signin'),
                    style: const TextStyle(
                      color: SC.textMuted,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.none,
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      labelText: AppStrings.t('login_email_label'),
                      hintText: AppStrings.t('login_email_hint'),
                      prefixIcon: const Icon(Icons.alternate_email,
                          color: SC.textMuted),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: !_showPassword,
                    enabled: !_busy,
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      labelText: AppStrings.t('login_password_label'),
                      prefixIcon: const Icon(Icons.lock_outline,
                          color: SC.textMuted),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: SC.textMuted,
                        ),
                      ),
                    ),
                  ),
                  if (!isSignUp) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : _forgotPassword,
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
                        icon: const Icon(Icons.mark_email_unread_outlined,
                            size: 18),
                        label: Text(AppStrings.t('login_resend_confirm')),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: SC.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            isSignUp
                                ? AppStrings.t('login_btn_signup')
                                : AppStrings.t('login_btn_signin'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
