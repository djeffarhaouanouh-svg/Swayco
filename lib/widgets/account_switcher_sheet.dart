import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../screens/login_screen.dart';
import '../services/account_switcher.dart';
import '../services/activity_signal.dart';
import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart' show popupDisplay;
import 'profile_avatar.dart';
import 'swayco_dialog.dart';

const Color _kYellow = Color(0xFFF4FF1F);

/// Le panneau « Changer de compte » (handoff `changer_compte`) : la liste des
/// comptes gardés sur ce téléphone, l'actif coché, « Ajouter un compte ». Sans
/// limite de nombre.
Future<void> showAccountSwitcher(BuildContext context) async {
  await AccountSwitcher.rememberCurrent();
  if (!context.mounted) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final action = await showModalBottomSheet<_Action>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _Sheet(messenger: messenger),
  );
  if (action == null) return;
  // « Ajouter un compte », ou jeton expiré : l'écran de connexion PAR-DESSUS
  // l'app, sans déconnecter le compte actif.
  final previous = await AccountSwitcher.beginAdd();
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          _AddAccountScreen(previousId: previous, email: action.email),
    ),
  );
  await AccountSwitcher.endAdd(previous);
}

class _Action {
  const _Action(this.email);
  final String email;
}

class _Sheet extends StatefulWidget {
  const _Sheet({required this.messenger});

  final ScaffoldMessengerState messenger;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  List<SavedAccount> _accounts = const [];
  String _switching = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final all = await AccountSwitcher.list();
    if (mounted) setState(() => _accounts = all);
  }

  void _say(String key) => widget.messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.t(key))),
      );

  Future<void> _pick(SavedAccount a) async {
    if (_switching.isNotEmpty) return;
    if (a.id == AuthService.currentUserId) {
      Navigator.of(context).pop();
      return;
    }
    if (ActivitySignal.inCall) {
      _say('switch_account_in_call');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _switching = a.id);
    // La bascule referme d'elle-même toutes les pages (dont ce panneau).
    final result = await AccountSwitcher.switchTo(a);
    if (result == SwitchResult.ok) return;
    if (result == SwitchResult.failed) {
      _say('switch_account_failed');
      if (mounted) setState(() => _switching = '');
      return;
    }
    // Jeton expiré : on propose de se reconnecter, e-mail prérempli.
    if (mounted) Navigator.of(context).pop(_Action(a.email));
  }

  Future<void> _remove(SavedAccount a) async {
    if (_switching.isNotEmpty || a.id == AuthService.currentUserId) return;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('switch_account_remove_title'),
      body: AppStrings.t('switch_account_remove_body'),
      confirmLabel: AppStrings.t('switch_account_remove_confirm'),
    );
    if (ok != true) return;
    await AccountSwitcher.remove(a.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.currentUserId;
    final grey = Colors.white.withValues(alpha: 0.6);
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      padding: EdgeInsets.fromLTRB(
        18,
        12,
        18,
        30 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        gradient: SC.callSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            AppStrings.t('switch_account'),
            style: popupDisplay(
              fontSize: 19,
              letterSpacing: -0.57,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _accounts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final a = _accounts[i];
                final active = a.id == me;
                final name = a.name.isEmpty ? a.email : a.name;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: _switching.isEmpty ? () => _pick(a) : null,
                    onLongPress: active ? null : () => _remove(a),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? _kYellow.withValues(alpha: 0.07)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: active
                              ? _kYellow.withValues(alpha: 0.5)
                              : Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: Row(
                        children: [
                          ProfileAvatar(
                            displayName: name,
                            avatarUrl: a.avatarUrl,
                            size: 48,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  a.email,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: grey,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (_switching == a.id)
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: _kYellow,
                              ),
                            )
                          else
                            Icon(
                              active
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              size: 26,
                              color: active
                                  ? _kYellow
                                  : Colors.white.withValues(alpha: 0.4),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _switching.isNotEmpty
                ? null
                : () {
                    if (ActivitySignal.inCall) {
                      _say('switch_account_in_call');
                      return;
                    }
                    Navigator.of(context).pop(const _Action(''));
                  },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: const StadiumBorder(),
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.28),
                width: 1.5,
              ),
            ),
            icon: const Icon(Icons.add, size: 22),
            label: Text(
              AppStrings.t('switch_account_add'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            AppStrings.t('switch_account_note'),
            textAlign: TextAlign.center,
            style: GoogleFonts.plusJakartaSans(color: grey, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// L'écran de connexion habituel, posé par-dessus l'app, avec une croix. Il se
/// referme dès qu'un AUTRE compte est connecté.
class _AddAccountScreen extends StatefulWidget {
  const _AddAccountScreen({required this.previousId, required this.email});

  final String previousId;
  final String email;

  @override
  State<_AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<_AddAccountScreen> {
  StreamSubscription<Object?>? _sub;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _sub = AuthService.onAuthStateChange.listen((_) {
      final uid = AuthService.currentUserId;
      if (_done || uid.isEmpty || uid == widget.previousId || !mounted) return;
      _done = true;
      Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        LoginScreen(initialEmail: widget.email),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Material(
              color: Colors.black.withValues(alpha: 0.35),
              shape: const CircleBorder(),
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip:
                    MaterialLocalizations.of(context).closeButtonTooltip,
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
