import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_strings.dart';
import '../services/swayco_sounds.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import '../widgets/sway_onb_kit.dart';
import '../widgets/swayco_wordmark.dart';
import 'forgot_password_screen.dart';

/// Photo framing: how far above the screen top it starts (more negative =
/// the whole group higher), and down to which fraction of its height it
/// stays sharp before melting into the gradient.
const double _kPhotoTop = -110;
const double _kPhotoSharpUntil = 0.78;

/// Welcome screen shown when the user has no Supabase Auth session — direction
/// 8c: the group photo on top melting into the onboarding's blue → cyan
/// gradient, the form below (white fields, yellow pill). After a successful
/// sign-in the parent (`main.dart`) reacts to the auth state change and routes
/// to onboarding / home.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Mode { signIn, signUp }

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  // A visitor with no session opens on account creation; someone who already
  // has an account switches with the link under the form.
  _Mode _mode = _Mode.signUp;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _info;

  /// True once we know the entered email exists but isn't confirmed yet —
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
        HapticFeedback.mediumImpact();
        SwaycoSounds.play(SwSound.welcome);
      }
      // Parent listens to auth state changes — it'll route us away.
    } on AuthException catch (e) {
      if (!mounted) return;
      // Surface the "Resend confirmation" affordance when the failure is
      // specifically "email not confirmed" so the user has a way forward
      // without retyping everything.
      final code = e.code ?? '';
      final msg = e.message.toLowerCase();
      final notConfirmed =
          code == 'email_not_confirmed' || msg.contains('email not confirmed');
      final invalidCredentials =
          code == 'invalid_credentials' ||
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

  /// Google / Apple: same busy / error handling. A null result = the user
  /// closed the sheet, so just drop the spinner; on success the parent's auth
  /// listener routes us away — leave _busy on so the form stays disabled.
  Future<void> _social(Future<dynamic> Function() run) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _showResendConfirmation = false;
    });
    try {
      final res = await run();
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
    final size = MediaQuery.sizeOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      // The gradient sits BEHIND the transparent Scaffold, so any strip the
      // body doesn't cover still shows it — a Scaffold colour here left a
      // dark band along the bottom.
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: SwayOnb.stepGradient),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SizedBox.expand(
            child: Stack(
              children: [
                // The photo, 58 % of the screen, pulled up under the status
                // bar ([_kPhotoTop]). It fades ITSELF out (dstIn) so the gradient shows
                // through with no seam. No blur anywhere under this mask.
                Positioned(
                  top: _kPhotoTop,
                  left: 0,
                  right: 0,
                  height: size.height * 0.58,
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      // Sharp down to the two girls at the bottom of the
                      // group; the fade only starts just above the title.
                      stops: [0, _kPhotoSharpUntil, 1],
                    ).createShader(rect),
                    child: Image.asset(
                      'assets/bienvenue_8c.jpg',
                      fit: BoxFit.cover,
                      // Crop from the BOTTOM of the source: the whole group
                      // rides up, the lower faces land above the title.
                      alignment: const Alignment(0, 1),
                    ),
                  ),
                ),
                // A light blue tint at the very top keeps the white status-bar
                // glyphs and the logo readable over the bright sky.
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 140,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x4D1F5EFF), Color(0x001F5EFF)],
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      children: [
                        const SizedBox(height: 18),
                        const SwaycoWordmark(
                          fontSize: 26,
                          oColor: SC.accent,
                          shadows: [
                            Shadow(color: Color(0x40000000), blurRadius: 8),
                          ],
                        ),
                        SizedBox(height: size.height * 0.30),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            22,
                            0,
                            22,
                            MediaQuery.paddingOf(context).bottom + 24,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 420),
                              child: _form(isSignUp),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(bool isSignUp) {
    final soft = Colors.white.withValues(alpha: 0.9);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwayTitle(
          isSignUp
              ? AppStrings.t('login_title_signup')
              : AppStrings.t('login_title_signin'),
          size: 30,
        ),
        const SizedBox(height: 10),
        Text(
          isSignUp
              ? AppStrings.t('login_subtitle_signup')
              : AppStrings.t('login_subtitle_signin'),
          style: SwayOnb.body.copyWith(fontSize: 14, color: soft),
        ),
        const SizedBox(height: 18),
        SwayInput(
          controller: _emailCtrl,
          hint: AppStrings.t('login_email_hint'),
          keyboardType: TextInputType.emailAddress,
          textCapitalization: TextCapitalization.none,
          enabled: !_busy,
        ),
        const SizedBox(height: 10),
        SwayInput(
          controller: _passwordCtrl,
          hint: AppStrings.t('login_password_label'),
          obscure: !_showPassword,
          textCapitalization: TextCapitalization.none,
          enabled: !_busy,
          trailing: IconButton(
            onPressed: () => setState(() => _showPassword = !_showPassword),
            icon: Icon(
              _showPassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: SwayOnb.hintOnWhite,
              size: 20,
            ),
          ),
        ),
        if (!isSignUp)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _openForgotPassword,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(
                AppStrings.t('login_forgot'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white,
                ),
              ),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(
              color: Color(0xFFFFE0D6),
              fontSize: 13,
              fontWeight: FontWeight.w700,
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
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
        if (_showResendConfirmation)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _resendConfirmation,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              icon: const Icon(Icons.mark_email_unread_outlined, size: 18),
              label: Text(AppStrings.t('login_resend_confirm')),
            ),
          ),
        const SizedBox(height: 14),
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
                  color: SC.onAccent,
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Divider(color: Colors.white.withValues(alpha: 0.35)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                AppStrings.t('login_or'),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: Divider(color: Colors.white.withValues(alpha: 0.35)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _SocialButton(
          leading: SvgPicture.asset(
            'assets/google-logo-search-new-svgrepo-com.svg',
            width: 20,
            height: 20,
          ),
          label: AppStrings.t('login_continue_google'),
          onPressed: _busy ? null : () => _social(AuthService.signInWithGoogle),
        ),
        if (_showApple) ...[
          const SizedBox(height: 8),
          _SocialButton(
            icon: Icons.apple,
            label: AppStrings.t('login_continue_apple'),
            onPressed: _busy
                ? null
                : () => _social(AuthService.signInWithApple),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                isSignUp
                    ? AppStrings.t('login_have_account')
                    : AppStrings.t('login_no_account'),
                style: TextStyle(color: soft, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _toggleMode,
              style: TextButton.styleFrom(
                foregroundColor: SC.accent,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: Text(
                isSignUp
                    ? AppStrings.t('login_btn_signin')
                    : AppStrings.t('login_btn_signup'),
                style: const TextStyle(
                  color: SC.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Continue with …" — white glass pill on the blue (16 % fill, 40 % edge).
/// Provider-agnostic (icon + label) so Google and Apple share one widget.
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
      icon: leading ?? Icon(icon, color: Colors.white, size: 22),
      label: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        backgroundColor: Colors.white.withValues(alpha: 0.16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.4)),
        shape: const StadiumBorder(),
      ),
    );
  }
}
