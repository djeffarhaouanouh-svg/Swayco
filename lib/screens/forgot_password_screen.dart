import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';

/// Reached from the "Mot de passe oublié ?" link on the login screen. One
/// field (email) + a send button that fires `AuthService.resetPassword`.
/// Then the 6-digit code from the email is typed HERE (no link to open, so it
/// works the same on iOS, Android and the web); a valid code opens the recovery
/// session and `main.dart` shows `NewPasswordScreen`. The email link still
/// works on the web.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    this.initialEmail = '',
    this.alreadySent = false,
  });

  /// Prefilled with whatever the user had already typed on the login form.
  final String initialEmail;

  /// L'e-mail avec le code est DÉJÀ parti (depuis les Réglages) : l'écran ouvre
  /// directement sur la saisie du code.
  final bool alreadySent;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _emailCtrl = TextEditingController(text: widget.initialEmail);
  final _codeCtrl = TextEditingController();
  late bool _sent = widget.alreadySent;
  bool _busy = false;
  String? _error;
  late String? _info =
      widget.alreadySent ? AppStrings.t('login_reset_sent') : null;

  // Same shape as the login form's check.
  static final _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$',
  );

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    setState(() {
      _error = null;
      _info = null;
    });
    if (!_emailRegex.hasMatch(email)) {
      setState(() => _error = AppStrings.t('login_err_email'));
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.resetPassword(email);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent = true;
        _info = AppStrings.t('login_reset_sent');
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('forgot password error: $e');
      setState(() {
        _busy = false;
        _error = AppStrings.t('login_err_generic');
      });
    }
  }

  /// Valide le code reçu. Réussi, le client émet passwordRecovery et l'écran
  /// du nouveau mot de passe prend la place de l'accueil : on referme cet
  /// écran pour le laisser apparaître.
  Future<void> _verifyCode() async {
    // Que les chiffres : on tolère un espace ou un collé-copié avec du texte.
    final code = _codeCtrl.text.replaceAll(RegExp(r'\D'), '');
    setState(() {
      _error = null;
      _info = null;
    });
    if (code.length != 6) {
      setState(() => _error = AppStrings.t('forgot_pw_code_invalid'));
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.verifyRecoveryCode(
        email: _emailCtrl.text,
        code: code,
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.t('forgot_pw_code_invalid');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.t('login_err_generic');
      });
    }
  }

  /// Demande un nouveau code (le précédent n'est plus valable).
  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.resetPassword(_emailCtrl.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _codeCtrl.clear();
        _info = AppStrings.t('login_reset_sent');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AppStrings.t('login_err_generic');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SwayOnb.screenBg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(color: Colors.white),
      ),
      body: SwayHalo(
        preset: SwayHaloPreset.login,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: SwayTitle(
                        AppStrings.t('forgot_pw_title'),
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      AppStrings.t('forgot_pw_subtitle'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
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
                      enabled: !_busy && !_sent,
                    ),
                    if (_sent) ...[
                      const SizedBox(height: 14),
                      SwayInput(
                        controller: _codeCtrl,
                        hint: AppStrings.t('forgot_pw_code_hint'),
                        keyboardType: TextInputType.number,
                        textCapitalization: TextCapitalization.none,
                        enabled: !_busy,
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
                    const SizedBox(height: 20),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SwayCta(
                          label: AppStrings.t(
                            _sent ? 'forgot_pw_code_cta' : 'forgot_pw_cta',
                          ),
                          onPressed: _busy
                              ? null
                              : _sent
                                  ? _verifyCode
                                  : _submit,
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
                    ),                    if (_sent) ...[
                      const SizedBox(height: 6),
                      Center(
                        child: TextButton(
                          onPressed: _busy ? null : _resend,
                          child: Text(AppStrings.t('forgot_pw_resend')),
                        ),
                      ),
                    ],

                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
