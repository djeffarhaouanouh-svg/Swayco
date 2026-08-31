import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';

/// Reached from the "Mot de passe oublié ?" link on the login screen. One
/// field (email) + a send button that fires `AuthService.resetPassword`.
/// The actual new-password step happens later, in `NewPasswordScreen`, when
/// the user comes back through the email link.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  /// Prefilled with whatever the user had already typed on the login form.
  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _emailCtrl = TextEditingController(text: widget.initialEmail);
  bool _busy = false;
  bool _sent = false;
  String? _error;
  String? _info;

  // Same shape as the login form's check.
  static final _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$',
  );

  @override
  void dispose() {
    _emailCtrl.dispose();
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
      setState(() {
        _busy = false;
        _error = '$e';
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
                      enabled: !_busy && !_sent,
                    ),
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
                            _sent ? 'login_btn_signin' : 'forgot_pw_cta',
                          ),
                          onPressed: _busy
                              ? null
                              : _sent
                                  ? () => Navigator.of(context).maybePop()
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
                    ),
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
