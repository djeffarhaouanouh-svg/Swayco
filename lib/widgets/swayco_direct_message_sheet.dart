import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Popup du message direct (direction 8c). Remplace `_DirectMessageSheet`
/// (discover_screen) : rend le texte saisi, ou null si fermée. L'envoi reste
/// fait par l'appelant.
class SwaycoDirectMessageSheet extends StatefulWidget {
  const SwaycoDirectMessageSheet({super.key});

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
                  onPressed: () {
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

