import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/languages.dart';
import '../services/user_prefs.dart';
import '../theme/swayco_theme.dart';

/// Mandatory "which language will you speak?" gate, shown right before every
/// call starts.
///
/// The account language (picked at onboarding) is only a DEFAULT here: it is
/// what the profile says the user speaks, but a call is a specific moment —
/// someone registered in French may want to practise their Japanese tonight.
/// The answer is what drives the whole call: it is minted into the LiveKit
/// token (so the peer's app knows which language to translate FROM), and it
/// selects the on-device recogniser.
///
/// The user cannot escape it: no barrier dismiss, no back button, no cancel
/// action. It returns only with a language.
Future<String?> askSpokenLanguage(
  BuildContext context, {
  required String preselect,
}) async {
  final saved = await UserPrefs.loadCallSpokenLang();

  // "Don't ask again" was ticked: answer from memory and never show the
  // dialog. This is the only way past the gate without a prompt.
  if (saved.dontAsk && saved.lang.isNotEmpty) return saved.lang;

  // Pre-selection order: the last language actually chosen for a call, then
  // the account language. The last choice wins because it is the more recent
  // statement of intent — someone who ran their last call in Japanese is more
  // likely to do it again than to revert to their profile language.
  final wanted = saved.lang.isNotEmpty ? saved.lang : preselect;
  // The dialog must always open on a valid row: there is no "none" answer.
  final initial = supportedLanguages.any((l) => l.code == wanted)
      ? wanted
      : supportedLanguages.first.code;

  if (!context.mounted) return null;
  final result = await showDialog<({String lang, bool dontAsk})>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SpokenLanguageDialog(initial: initial),
  );
  if (result == null) return null;
  // Remembered even when the box is unticked — it becomes the pre-selection.
  await UserPrefs.saveCallSpokenLang(result.lang, dontAsk: result.dontAsk);
  return result.lang;
}

class _SpokenLanguageDialog extends StatefulWidget {
  const _SpokenLanguageDialog({required this.initial});

  final String initial;

  @override
  State<_SpokenLanguageDialog> createState() => _SpokenLanguageDialogState();
}

class _SpokenLanguageDialogState extends State<_SpokenLanguageDialog> {
  late String _selected = widget.initial;
  bool _dontAsk = false;

  @override
  Widget build(BuildContext context) {
    // canPop: false also blocks the Android hardware back button and the iOS
    // edge swipe — barrierDismissible alone would leave both open.
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0E0E0E),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: SC.glassBorderStrong),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 30,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppStrings.t('call_lang_gate_title'), style: SCText.h3),
              const SizedBox(height: 10),
              Text(
                AppStrings.t('call_lang_gate_body'),
                style: SCText.body.copyWith(
                  color: SC.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              // Bounded so a long language list scrolls inside the dialog
              // instead of pushing the confirm button off a small screen.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: Scrollbar(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: supportedLanguages.length,
                    itemBuilder: (_, i) {
                      final lang = supportedLanguages[i];
                      final picked = lang.code == _selected;
                      return InkWell(
                        onTap: () => setState(() => _selected = lang.code),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 11),
                          decoration: BoxDecoration(
                            color: picked ? SC.bubbleIn : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: picked
                                  ? SC.glassBorderStrong
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(lang.flag,
                                  style: const TextStyle(fontSize: 20)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  lang.label,
                                  style: TextStyle(
                                    color: picked
                                        ? SC.textPrimary
                                        : SC.textSecondary,
                                    fontSize: 15,
                                    fontWeight: picked
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (picked)
                                const Icon(Icons.check_rounded,
                                    color: SC.textPrimary, size: 20),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Opt-out of the prompt itself. Unticked by default: the gate
              // exists because the account language is often NOT the one being
              // spoken, so silently reusing a choice has to be deliberate.
              InkWell(
                onTap: () => setState(() => _dontAsk = !_dontAsk),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _dontAsk,
                        onChanged: (v) => setState(() => _dontAsk = v ?? false),
                        side: const BorderSide(color: SC.textMuted),
                        checkColor: const Color(0xFF0E0E0E),
                        activeColor: SC.textPrimary,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          AppStrings.t('call_lang_gate_dont_ask'),
                          style: const TextStyle(
                              color: SC.textSecondary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // No cancel: answering is the only way out.
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .pop((lang: _selected, dontAsk: _dontAsk)),
                style: FilledButton.styleFrom(
                  backgroundColor: SC.textPrimary,
                  foregroundColor: const Color(0xFF0E0E0E),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  AppStrings.t('call_lang_gate_confirm'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
