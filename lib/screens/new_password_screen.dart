import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';
import '../services/friendly_error.dart';

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
          _error = friendlyError(e);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwayAuthPage(
      title: AppStrings.t('reset_pw_title'),
      subtitle: AppStrings.t('reset_pw_subtitle'),
      children: [
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
              color: SwayOnb.hintOnWhite,
              size: 20,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SwayInput(
          controller: _confirmCtrl,
          hint: AppStrings.t('reset_pw_confirm_hint'),
          obscure: !_show,
          enabled: !_busy,
          textCapitalization: TextCapitalization.none,
        ),
        if (_error != null) SwayAuthMessage(_error!, error: true),
        if (_info != null) SwayAuthMessage(_info!),
        const SizedBox(height: 18),
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
        Center(
          child: TextButton(
            onPressed: _busy ? null : widget.onDone,
            style: TextButton.styleFrom(foregroundColor: SC.accent),
            child: Text(
              AppStrings.t('login_btn_signin'),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}
