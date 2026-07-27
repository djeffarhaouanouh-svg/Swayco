import 'package:flutter/material.dart';

import '../theme/swayco_theme.dart';
import 'app_strings.dart';

/// Soft "pre-permission priming" sheet shown BEFORE the real OS prompt.
///
/// iOS only lets an app trigger the native notification/mic dialog once — a
/// refusal there is final (only Settings can undo it). So we never fire the
/// OS prompt cold: this sheet explains the benefit first, and only if the
/// user taps the primary button does the caller trigger the real prompt.
/// Tapping "later" / dismissing returns false and preserves the one-shot.
abstract final class PermissionPriming {
  static Future<bool> show(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final res = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF0A0A0A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _PrimingSheet(
        icon: icon,
        title: title,
        body: body,
        confirmLabel: confirmLabel,
      ),
    );
    return res ?? false;
  }
}

class _PrimingSheet extends StatelessWidget {
  const _PrimingSheet({
    required this.icon,
    required this.title,
    required this.body,
    required this.confirmLabel,
  });

  final IconData icon;
  final String title;
  final String body;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 22),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              width: 88,
              height: 88,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: SC.accent.withValues(alpha: 0.15),
              ),
              child: Icon(icon, color: SC.accent, size: 42),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(confirmLabel),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                AppStrings.t('prime_later'),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
