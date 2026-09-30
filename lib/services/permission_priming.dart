import 'package:flutter/material.dart';

import '../widgets/popup_kit.dart';
import 'app_strings.dart';

/// Feuille « pré-permission » affichée AVANT la vraie demande de l'OS
/// (direction 8c). iOS ne laisse qu'un essai : on explique d'abord, et on ne
/// déclenche la demande native que si l'utilisateur touche le bouton principal.
/// Même signature qu'avant.
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
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: true,
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
    return PopupSurface(
      sheet: true,
      washHeight: 150,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: PopupHandle()),
              const SizedBox(height: 6),
              Center(child: PopupBadge(icon: icon, size: 84)),
              const SizedBox(height: 16),
              PopupTitle(title, fontSize: 20),
              const SizedBox(height: 10),
              PopupBody(body),
              const SizedBox(height: 24),
              PopupButton(
                label: confirmLabel,
                height: 54,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  AppStrings.t('prime_later'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

