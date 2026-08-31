import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';

/// Shown when the app is opened from a Supabase password-recovery link
/// (`AuthChangeEvent.passwordRecovery`, or a `type=recovery` launch URL on
/// web). The link has already established a short-lived session; here the
/// user picks a new password, which `auth.updateUser` writes. On success we
/// sign that recovery session out and hand back to `main.dart` so the login
/// screen takes over — the user signs in fresh with the new password.
class NewPasswordScreen extends StatefulWidget {
  const NewPasswordScreen({super.key, required this.onDone});

  /// Called once the flow is finished (success, or the user backed out) so
  /// the caller can drop the recovery route and show login again.
  final VoidCallback onDone;

  @override
  State<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends State<NewPasswordScreen> {
  final _pwCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _pwCtrl.text;
    setState(() {
      _error = null;
      _info = null;
    });
    // Same 6-char floor the sign-up form enforces (login_screen._submit).
    if (pw.length < 6) {
      setState(() => _error = AppStrings.t('login_err_password'));
      return;
    }
    if (pw != _confirmCtrl.text) {
      setState(() => _error = AppStrings.t('reset_pw_mismatch'));
      return;
    }
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: pw),
      );
      // The recovery link's session must not silently become a real login —
      // sign it out and route the user back to the login screen.
      await AuthService.signOut();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _info = AppStrings.t('reset_pw_success');
      });
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) widget.onDone();
    } on AuthException catch (e) {
      if (!mounted) return;
      final msg = e.message.toLowerCase();
      final code = e.code ?? '';
      setState(() {
        _busy = false;
        if (code == 'same_password' || msg.contains('should be different')) {
          _error = AppStrings.t('reset_pw_same');
        } else if (code == 'session_not_found' ||
            msg.contains('expired') ||
            msg.contains('invalid') ||
            msg.contains('session')) {
          _error = AppStrings.t('reset_pw_expired');
        } else {
          _error = e.message;
        }
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
      body: SwayHalo(
        preset: SwayHaloPreset.login,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: SwayTitle(
                        AppStrings.t('reset_pw_title'),
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      AppStrings.t('reset_pw_subtitle'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: SC.textMuted,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 26),
                    SwayInput(
                      controller: _pwCtrl,
                      hint: AppStrings.t('reset_pw_new_hint'),
                      obscure: !_show,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.none,
                      trailing: IconButton(
                        onPressed: () => setState(() => _show = !_show),
                        icon: Icon(
                          _show
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: SwayOnb.dim,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwayInput(
                      controller: _confirmCtrl,
                      hint: AppStrings.t('reset_pw_confirm_hint'),
                      obscure: !_show,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.none,
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
                          label: AppStrings.t('reset_pw_cta'),
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
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy ? null : widget.onDone,
                      child: Text(AppStrings.t('login_btn_signin')),
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
