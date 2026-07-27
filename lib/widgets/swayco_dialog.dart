import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// Shared "yes/no" confirmation dialog in the Midnight palette. Returns
/// `true` when the user picks the confirm action, `false` (or `null`) on
/// cancel / barrier dismiss. Use it everywhere instead of hand-rolled
/// [AlertDialog]s so the look stays consistent.
Future<bool?> showSwaycoConfirm({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = true,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _SwaycoConfirmDialog(
      title: title,
      body: body,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel ?? AppStrings.t('cancel'),
      destructive: destructive,
    ),
  );
}

class _SwaycoConfirmDialog extends StatelessWidget {
  const _SwaycoConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        decoration: BoxDecoration(
          // Site black (same surface as the profile / chat) instead of the
          // lighter bubble grey.
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
            Text(title, style: SCText.h3),
            const SizedBox(height: 10),
            Text(
              body,
              style: SCText.body.copyWith(
                color: SC.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    foregroundColor: SC.textMuted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  child: Text(cancelLabel),
                ),
                const SizedBox(width: 8),
                _ConfirmButton(
                  label: confirmLabel,
                  destructive: destructive,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({
    required this.label,
    required this.destructive,
    required this.onTap,
  });

  final String label;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gradient = destructive
        ? const LinearGradient(
            colors: [Color(0xFFEF4444), Color(0xFFB91C1C)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [SC.accent, SC.accentDeep],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          );
    final glow = destructive
        ? const Color(0xFFEF4444).withValues(alpha: 0.35)
        : SC.accent.withValues(alpha: 0.4);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: gradient,
        boxShadow: [
          BoxShadow(color: glow, blurRadius: 16, offset: const Offset(0, 6)),
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
            child: Text(
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
