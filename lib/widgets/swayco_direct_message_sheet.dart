import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/special_message_quota.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Popup du message direct (direction 8c). Remplace `_DirectMessageSheet`
/// (discover_screen) : rend le texte saisi, ou null si fermée. L'envoi reste
/// fait par l'appelant.
class SwaycoDirectMessageSheet extends StatefulWidget {
  const SwaycoDirectMessageSheet({
    super.key,
    this.remaining = SpecialMessageQuota.monthly,
  });

  /// Messages spéciaux qu'il reste ce mois-ci (3 → 0).
  final int remaining;

  @override
  State<SwaycoDirectMessageSheet> createState() =>
      _SwaycoDirectMessageSheetState();
}

class _SwaycoDirectMessageSheetState extends State<SwaycoDirectMessageSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static OutlineInputBorder _b(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: c, width: w),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: PopupSurface(
        sheet: true,
        washHeight: 140,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: PopupHandle()),
                const SizedBox(height: 4),
                const Center(
                  child: PopupBadge(icon: Icons.chat_bubble_rounded, size: 52),
                ),
                const SizedBox(height: 14),
                const SizedBox(height: 10),
                Center(child: _QuotaPill(remaining: widget.remaining)),
                const SizedBox(height: 12),
                PopupBody(AppStrings.t('dm_explain')),
                const SizedBox(height: 16),
                TextField(
                  controller: _ctrl,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 500,
                  cursorColor: SC.accentFg,
                  textCapitalization: TextCapitalization.sentences,
                  style: SCText.subtitle.copyWith(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('dm_write_hint'),
                    hintStyle: SCText.subtitle.copyWith(
                      fontSize: 16,
                      color: SC.fg.withValues(alpha: 0.4),
                    ),
                    counterText: '',
                    filled: true,
                    fillColor: PopupTokens.ghost,
                    contentPadding: const EdgeInsets.all(16),
                    border: _b(PopupTokens.ghostBorder),
                    enabledBorder: _b(PopupTokens.ghostBorder),
                    focusedBorder: _b(SC.accentFg, 1.5),
                  ),
                ),
                const SizedBox(height: 14),
                PopupButton(
                  label: AppStrings.t('send_emoji'),
                  height: 54,
                  onPressed: widget.remaining <= 0
                      ? null
                      : () {
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
}


/// « 3/3 messages spéciaux restants » — pastille sous l'icône.
class _QuotaPill extends StatelessWidget {
  const _QuotaPill({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    final empty = remaining <= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: PopupTokens.ghost,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: PopupTokens.ghostBorder),
      ),
      child: Text(
        empty
            ? AppStrings.t('dm_quota_empty')
            : AppStrings.t(
                'dm_quota',
                args: {
                  'n': '$remaining',
                  'max': '${SpecialMessageQuota.monthly}',
                },
              ),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: empty ? PopupTokens.danger : PopupTokens.ink,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
