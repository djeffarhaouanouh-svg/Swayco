import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../services/special_message_quota.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';
import 'profile_avatar.dart';

/// Feuille « Message spécial » (déjà Pro) : en-tête avec les 3 étincelles du
/// quota, phrase d'explication, pastille destinataire, champ et bouton
/// Envoyer. Rend le texte saisi, ou null si fermée ; l'envoi reste fait par
/// l'appelant.
class SwaycoDirectMessageSheet extends StatefulWidget {
  const SwaycoDirectMessageSheet({
    super.key,
    this.remaining = SpecialMessageQuota.total,
    this.peer,
  });

  /// Messages spéciaux qu'il reste (3 → 0).
  final int remaining;

  /// La personne à qui on écrit (prénom + avatar).
  final RemoteProfile? peer;

  @override
  State<SwaycoDirectMessageSheet> createState() =>
      _SwaycoDirectMessageSheetState();
}

class _SwaycoDirectMessageSheetState extends State<SwaycoDirectMessageSheet> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _empty => widget.remaining <= 0;

  String get _firstName {
    final n = widget.peer?.displayName.trim() ?? '';
    return n.isEmpty ? AppStrings.t('incoming_someone') : n.split(RegExp(r'\s+')).first;
  }

  Color get _accentLine => SC.light ? const Color(0xFF1F5EFF) : SC.accent;

  @override
  Widget build(BuildContext context) {
    final ink = PopupTokens.ink;
    final name = _firstName;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: PopupSurface(
        sheet: true,
        washHeight: 170,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: PopupHandle()),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment(-0.6, -1),
                          end: Alignment(0.6, 1),
                          colors: [
                            SC.brandBlueDeep,
                            SC.brandBlue,
                            SC.brandCyan,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0xD92B7FFF),
                            blurRadius: 18,
                            spreadRadius: -8,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: SvgPicture.asset(
                        'assets/icons/pro/pro_messages_speciaux.svg',
                        width: 36,
                        height: 36,
                        colorFilter: const ColorFilter.mode(
                          SC.accent,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            AppStrings.t('special_label'),
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: popupDisplay(fontSize: 19, color: ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _empty
                                ? AppStrings.t('dm_quota_empty')
                                : AppStrings.t(
                                    'dm_left',
                                    args: {'n': '${widget.remaining}'},
                                  ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _empty
                                  ? (SC.light
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFFFF8A8A))
                                  : ink.withValues(alpha: 0.7),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    for (var i = 0; i < SpecialMessageQuota.total; i++) ...[
                      if (i > 0) const SizedBox(width: 5),
                      _Spark(filled: i < widget.remaining),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  AppStrings.t('dm_intro', args: {'name': name}),
                  style: TextStyle(
                    color: PopupTokens.textBody,
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(5, 5, 12, 5),
                    decoration: BoxDecoration(
                      color: PopupTokens.ghost,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: PopupTokens.ghostBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ProfileAvatar(
                          displayName: widget.peer?.displayName ?? '',
                          avatarUrl: widget.peer?.avatarUrl,
                          fallbackUrl: widget.peer?.fallbackPhotoUrl,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          AppStrings.t('dm_to', args: {'name': name}),
                          softWrap: false,
                          style: TextStyle(
                            color: ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Opacity(
                  opacity: _empty ? 0.55 : 1,
                  child: Stack(
                    children: [
                      TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        enabled: !_empty,
                        autofocus: !_empty,
                        minLines: 4,
                        maxLines: 6,
                        maxLength: 500,
                        cursorColor: _accentLine,
                        textCapitalization: TextCapitalization.sentences,
                        style: SCText.subtitle.copyWith(fontSize: 16),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: AppStrings.t('dm_write_hint'),
                          hintStyle: SCText.subtitle.copyWith(
                            fontSize: 16,
                            color: PopupTokens.inkMuted,
                          ),
                          counterText: '',
                          filled: true,
                          fillColor: PopupTokens.ghost,
                          contentPadding:
                              const EdgeInsets.fromLTRB(16, 16, 16, 30),
                          border: _b(PopupTokens.ghostBorder),
                          enabledBorder: _b(PopupTokens.ghostBorder),
                          disabledBorder: _b(PopupTokens.ghostBorder),
                          focusedBorder: _b(_accentLine, 1.5),
                        ),
                      ),
                      Positioned(
                        right: 14,
                        bottom: 10,
                        child: Text(
                          '${_ctrl.text.length}/500',
                          style: GoogleFonts.ibmPlexMono(
                            fontSize: 11,
                            color: PopupTokens.inkMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SendButton(
                  enabled: !_empty && _ctrl.text.trim().isNotEmpty,
                  label: AppStrings.t('send_emoji'),
                  onTap: () {
                    final t = _ctrl.text.trim();
                    if (t.isNotEmpty) Navigator.of(context).pop(t);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _b(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: c, width: w),
      );
}

/// Une étincelle du quota : jaune pleine = il en reste, vide = utilisée.
class _Spark extends StatelessWidget {
  const _Spark({required this.filled});

  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? SC.accent : PopupTokens.ghost,
        border: filled ? null : Border.all(color: PopupTokens.ghostBorder),
      ),
      child: Text(
        '✦',
        style: TextStyle(
          fontSize: 12,
          height: 1,
          color: filled ? SC.onAccent : const Color(0x661F5EFF),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.label,
    required this.onTap,
  });

  final bool enabled;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? SC.onAccent : PopupTokens.ink.withValues(alpha: 0.4);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? SC.accent : PopupTokens.ghost,
          borderRadius: BorderRadius.circular(999),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: SC.accent.withValues(alpha: 0.55),
                    blurRadius: 24,
                    spreadRadius: -8,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.send_rounded, size: 20, color: fg),
            const SizedBox(width: 8),
            Text(label, style: popupDisplay(fontSize: 15, color: fg)),
          ],
        ),
      ),
    );
  }
}