import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import 'popup_kit.dart';

/// Confirmation oui / non partagée (direction 8c). Renvoie `true` si
/// l'utilisateur confirme, `false` / `null` sinon. Même signature qu'avant,
/// plus un [icon] optionnel : aucun appel existant à modifier.
Future<bool?> showSwaycoConfirm({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = true,
  IconData? icon,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: PopupTokens.scrim,
    builder: (ctx) => _SwaycoConfirmDialog(
      title: title,
      body: body,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel ?? AppStrings.t('cancel'),
      destructive: destructive,
      icon: icon ??
          (destructive
              ? Icons.delete_outline_rounded
              : Icons.help_outline_rounded),
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
    required this.icon,
  });

  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      child: PopupSurface(
        danger: destructive,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: PopupBadge(icon: icon, danger: destructive)),
              const SizedBox(height: 14),
              PopupTitle(title, highlightLast: false),
              const SizedBox(height: 10),
              PopupBody(body),
              const SizedBox(height: 22),
              PopupButton(
                label: confirmLabel,
                danger: destructive,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 8),
              PopupGhostButton(
                label: cancelLabel,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

