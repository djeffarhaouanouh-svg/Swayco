import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';
import 'profile_avatar.dart';

/// Message d'information avec une icône et un ou deux boutons (direction 8c).
/// Remplace les `AlertDialog` bruts. Renvoie `true` sur le bouton principal,
/// `false` sur le secondaire, `null` si fermé autrement.
Future<bool?> showSwaycoNotice({
  required BuildContext context,
  required IconData icon,
  required String message,
  required String buttonLabel,
  String? secondaryLabel,
  bool danger = false,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      child: PopupSurface(
        danger: danger,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: PopupBadge(icon: icon, danger: danger)),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: SCText.subtitle.copyWith(
                  fontSize: 15,
                  height: 1.45,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 22),
              PopupButton(
                label: buttonLabel,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                PopupGhostButton(
                  label: secondaryLabel,
                  onPressed: () => Navigator.of(ctx).pop(false),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Saisie d'une courte chaîne (prénom…). Remplace `_NamePromptDialog`
/// (profile_screen) et `_TextPromptDialog` (settings_screen) : mêmes
/// paramètres, même valeur de retour (texte, ou null si annulé).
class SwaycoTextPromptDialog extends StatelessWidget {
  const SwaycoTextPromptDialog({
    super.key,
    required this.title,
    required this.controller,
    required this.maxLength,
  });

  final String title;
  final TextEditingController controller;
  final int maxLength;

  static OutlineInputBorder _b(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c, width: w),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      child: PopupSurface(
        washHeight: 100,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PopupTitle(
                title,
                fontSize: 18,
                textAlign: TextAlign.start,
                highlightLast: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: maxLength,
                textCapitalization: TextCapitalization.words,
                cursorColor: SC.accent,
                style: SCText.subtitle.copyWith(fontSize: 16),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: PopupTokens.ghost,
                  contentPadding: const EdgeInsets.all(14),
                  counterStyle: SCText.meta,
                  border: _b(PopupTokens.ghostBorder),
                  enabledBorder: _b(PopupTokens.ghostBorder),
                  focusedBorder: _b(SC.accent, 1.5),
                ),
                onSubmitted: (v) => Navigator.of(context).pop(v),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: PopupGhostButton(
                      label: AppStrings.t('cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PopupButton(
                      label: AppStrings.t('save'),
                      height: 48,
                      onPressed: () =>
                          Navigator.of(context).pop(controller.text),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Appel entrant. Remplace `_IncomingCallDialog` (root_shell) : mêmes
/// paramètres, plus [beforeAccept] (appelé juste avant `pop(true)`, y mettre
/// `armCallAudio(); armSpeechSynthesis();`). Refus automatique après 30 s.
class SwaycoIncomingCallDialog extends StatefulWidget {
  const SwaycoIncomingCallDialog({
    super.key,
    required this.callerName,
    required this.callerAvatarUrl,
    required this.callerAvatarColor,
    this.beforeAccept,
  });

  final String callerName;
  final String? callerAvatarUrl;
  final String? callerAvatarColor;
  final VoidCallback? beforeAccept;

  @override
  State<SwaycoIncomingCallDialog> createState() =>
      _SwaycoIncomingCallDialogState();
}

class _SwaycoIncomingCallDialogState extends State<SwaycoIncomingCallDialog> {
  static const _timeout = Duration(seconds: 30);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_timeout, () {
      if (mounted) Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _accept() {
    widget.beforeAccept?.call();
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: PopupSurface(
        washHeight: 160,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Toute la zone héros accepte l'appel, comme le bouton jaune.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _accept,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SC.brandGradient,
                        boxShadow: [
                          BoxShadow(
                            color: SC.brandBlue.withValues(alpha: 0.55),
                            blurRadius: 34,
                            spreadRadius: -4,
                          ),
                        ],
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: PopupTokens.surface,
                        ),
                        child: ProfileAvatar(
                          displayName: widget.callerName,
                          avatarUrl: widget.callerAvatarUrl,
                          size: 88,
                          fontSize: 36,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      widget.callerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: popupDisplay(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.66,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      AppStrings.t('incoming_call_label'),
                      style: SCText.subtitle.copyWith(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundAction(
                    icon: Icons.call_end,
                    label: AppStrings.t('decline'),
                    color: PopupTokens.danger,
                    iconColor: Colors.white,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  _RoundAction(
                    icon: Icons.call,
                    label: AppStrings.t('accept'),
                    color: SC.accent,
                    iconColor: SC.onAccent,
                    onTap: _accept,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon, color: iconColor, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: SCText.subtitle.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

