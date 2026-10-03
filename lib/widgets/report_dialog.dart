import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/report_api.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// Pop-up de signalement (direction 8c). Mêmes paramètres et même valeur de
/// retour qu'avant : `true` si le signalement est envoyé.
Future<bool> showReportDialog(
  BuildContext context, {
  required String reporterId,
  required String reportedId,
  required String peerName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: PopupTokens.scrim,
    builder: (ctx) => _ReportDialog(
      reporterId: reporterId,
      reportedId: reportedId,
      peerName: peerName,
    ),
  );
  return result == true;
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({
    required this.reporterId,
    required this.reportedId,
    required this.peerName,
  });

  final String reporterId;
  final String reportedId;
  final String peerName;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  ReportReason _reason = ReportReason.harassment;
  final _detailsCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final ok = await ReportApi.submit(
      reporterId: widget.reporterId,
      reportedId: widget.reportedId,
      reason: _reason,
      details: _detailsCtrl.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('report_thanks'))),
      );
    } else {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('report_failed'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: PopupSurface(
        washHeight: 100,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PopupTitle(
                AppStrings.t('report_q', args: {'name': widget.peerName}),
                fontSize: 18,
                textAlign: TextAlign.start,
                highlightLast: false,
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupBody(
                        AppStrings.t('report_body'),
                        textAlign: TextAlign.start,
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final r in ReportReason.values)
                            _ReasonChip(
                              label: AppStrings.t(r.i18nKey),
                              selected: r == _reason,
                              onTap: _submitting
                                  ? null
                                  : () => setState(() => _reason = r),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _detailsCtrl,
                        enabled: !_submitting,
                        minLines: 3,
                        maxLines: 4,
                        maxLength: 500,
                        cursorColor: SC.accentFg,
                        style: SCText.subtitle.copyWith(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: AppStrings.t('report_details_hint'),
                          hintStyle: SCText.subtitle.copyWith(
                            fontSize: 14,
                            color: SC.fg.withValues(alpha: 0.5),
                          ),
                          counterStyle: SCText.meta,
                          filled: true,
                          fillColor: PopupTokens.ghost,
                          contentPadding: const EdgeInsets.all(14),
                          border: _border(PopupTokens.ghostBorder),
                          enabledBorder: _border(PopupTokens.ghostBorder),
                          focusedBorder: _border(SC.accentFg),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: PopupGhostButton(
                      label: AppStrings.t('cancel'),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 6 ~/ 5 + 1,
                    child: PopupButton(
                      label: AppStrings.t('report_submit'),
                      danger: true,
                      busy: _submitting,
                      height: 48,
                      onPressed: _submit,
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

  static OutlineInputBorder _border(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c),
      );
}

class _ReasonChip extends StatelessWidget {
  const _ReasonChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? SC.accent : PopupTokens.ghost,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? SC.accentFg : PopupTokens.ghostBorder,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? SC.onAccent : SC.fg,
          ),
        ),
      ),
    );
  }
}

