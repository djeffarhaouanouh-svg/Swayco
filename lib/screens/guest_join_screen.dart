import 'dart:math';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/guest_invite_api.dart';
import '../services/languages.dart';
import '../services/token_api.dart';
import '../theme/swayco_theme.dart';
import '../swayco/realtime_translation_port.dart';
import 'call_screen.dart';

/// Landing screen for an invite link (`/c/<room>?t=â€¦&e=â€¦`). The guest enters
/// a first name + spoken language and joins the call â€” no account, no signup.
/// Only ever shown on web, routed to from `main.dart` when the URL carries a
/// guest-invite deep link.
class GuestJoinScreen extends StatefulWidget {
  const GuestJoinScreen({
    super.key,
    required this.invite,
    required this.translation,
  });

  final GuestInvite invite;
  final RealtimeTranslationPort translation;

  @override
  State<GuestJoinScreen> createState() => _GuestJoinScreenState();
}

class _GuestJoinScreenState extends State<GuestJoinScreen> {
  String? _selectedLang;
  bool _joining = false;
  String? _error;

  /// Random LiveKit identity for this guest. `guest-` prefix only â€” guests
  /// have no device id or account to derive a stable one from.
  String _newIdentity() {
    final r = Random();
    return 'guest-${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(999999)}';
  }

  /// Flip the whole UI to the guest's language as soon as they pick it, so
  /// the rest of the screen (and the call) reads in their language.
  void _onLanguageSelected(String code) {
    AppStrings.setFromCode(code);
    setState(() => _selectedLang = code);
  }

  Future<void> _join() async {
    if (_selectedLang == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('guest_need_lang'))),
      );
      return;
    }
    // No name is asked of the guest â€” they show up as "InvitÃ©" / "Guest".
    final name = AppStrings.t('guest_default_name');
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final token = await fetchLiveKitToken(
        roomName: widget.invite.roomName,
        identity: _newIdentity(),
        displayName: name,
        sourceLang: _selectedLang!,
        inviteSig: widget.invite.sig,
        inviteExp: widget.invite.exp,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            wsUrl: token.url,
            jwt: token.token,
            roomName: token.roomName,
            displayName: name,
            mySourceLang: _selectedLang!,
            translation: widget.translation,
          ),
        ),
      );
      // Returned from the call â€” let the guest rejoin if they want.
      if (mounted) setState(() => _joining = false);
    } on TokenApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = e.statusCode == 403
            ? AppStrings.t('guest_link_expired')
            : AppStrings.t('guest_join_error');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = AppStrings.t('guest_join_error');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: SC.accentDeep,
                    ),
                    child: const Icon(Icons.videocam_rounded,
                        color: Colors.white, size: 36),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    AppStrings.t('guest_title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.t('guest_subtitle'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: SC.textMuted,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    AppStrings.t('guest_lang_label'),
                    style: const TextStyle(
                      color: SC.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final lang in supportedLanguages)
                        _LangChip(
                          language: lang,
                          selected: lang.code == _selectedLang,
                          onTap: _joining
                              ? null
                              : () => _onLanguageSelected(lang.code),
                        ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFFAB91),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _joining ? null : _join,
                    child: _joining
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(AppStrings.t('guest_connecting')),
                            ],
                          )
                        : Text(AppStrings.t('guest_join_cta')),
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

class _LangChip extends StatelessWidget {
  const _LangChip({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final AppLanguage language;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? SC.accent : SC.bubbleIn;
    final border =
        selected ? SC.accent : Colors.white.withValues(alpha: 0.08);
    final fg = selected ? Colors.white : SC.textPrimary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(language.flag, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Text(
                language.label,
                style: TextStyle(
                    color: fg, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
