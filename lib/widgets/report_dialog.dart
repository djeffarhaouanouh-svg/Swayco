import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/report_api.dart';
import '../theme/swayco_theme.dart';

/// Modal that asks the user to pick a moderation reason + optional
/// details, then submits via [ReportApi].
///
/// Returns `true` if the report was successfully submitted, `false` if
/// the user cancelled, and surfaces failures via a snackbar on the
/// supplied [context]. Either way the underlying dialog is closed
/// before this returns.
///
/// Designed to be called from anywhere a peer is reachable (profile
/// screen, chat list, in-thread menu, etc.).
Future<bool> showReportDialog(
  BuildContext context, {
  required String reporterId,
  required String reportedId,
  required String peerName,
}) async {
  final result = await showDialog<bool>(
    context: context,
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
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        decoration: BoxDecoration(
          // Le gris des menus : ce dialogue s'ouvre depuis le ⋮, il porte la
          // même surface que lui.
          color: SC.menu,
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppStrings.t('report_q', args: {'name': widget.peerName}),
              style: SCText.h3,
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppStrings.t('report_body'),
                      style: SCText.body.copyWith(
                        color: SC.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final r in ReportReason.values)
                      RadioListTile<ReportReason>(
                        value: r,
                        groupValue: _reason,
                        onChanged: _submitting
                            ? null
                            : (v) => setState(() => _reason = v ?? _reason),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        activeColor: SC.accent,
                        title: Text(
                          AppStrings.t(r.i18nKey),
                          style: const TextStyle(
                            color: SC.textPrimary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _detailsCtrl,
                      enabled: !_submitting,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 500,
                      cursorColor: SC.accent,
                      style: const TextStyle(color: SC.textPrimary),
                      decoration: InputDecoration(
                        hintText: AppStrings.t('report_details_hint'),
                        hintStyle:
                            const TextStyle(color: SC.textMuted),
                        counterStyle:
                            const TextStyle(color: SC.textMuted, fontSize: 11),
                        filled: true,
                        fillColor: SC.glassStrong,
                        border: OutlineInputBorder(
                          borderSide:
                              const BorderSide(color: SC.glassBorder),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide:
                              const BorderSide(color: SC.glassBorder),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: const BorderSide(color: SC.accent),
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: SC.textMuted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  child: Text(AppStrings.t('cancel')),
                ),
                const SizedBox(width: 8),
                _ReportSubmitButton(
                  label: AppStrings.t('report_submit'),
                  busy: _submitting,
                  onTap: _submitting ? null : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportSubmitButton extends StatelessWidget {
  const _ReportSubmitButton({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFFEF4444), Color(0xFFB91C1C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFEF4444).withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
