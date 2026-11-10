import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart';

/// « Impossible de charger les profils » (écran 2d) : posé à la place de la
/// pile de cartes quand le chargement a ÉCHOUÉ — pas quand il n'y a personne
/// (ces textes-là, `discover_empty_*`, diraient quelque chose de faux ici).
class LoadFailedView extends StatelessWidget {
  const LoadFailedView({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final blue = SC.light ? SC.brandBlue : const Color(0xFF18DDEA);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (SC.light ? const Color(0xFF2B7FFF) : const Color(0xFF1F5EFF))
                    .withValues(alpha: SC.light ? 0.10 : 0.2),
                border: Border.all(
                  color: (SC.light
                          ? const Color(0xFF1F5EFF)
                          : const Color(0xFF18DDEA))
                      .withValues(alpha: SC.light ? 0.4 : 0.5),
                  width: 1.2,
                ),
              ),
              child: Icon(Icons.cloud_off_rounded, size: 48, color: blue),
            ),
            const SizedBox(height: 26),
            Text(
              AppStrings.t('fail_discover_title'),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: popupDisplay(
                fontSize: 28,
                letterSpacing: -0.84,
                height: 1.15,
                color: SC.fg,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                AppStrings.t('fail_discover_body'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.5,
                  color: SC.fg.withValues(alpha: 0.7),
                ),
              ),
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: 230,
              height: 56,
              child: FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: SC.onAccent,
                  shape: const StadiumBorder(),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.refresh_rounded, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        AppStrings.t('fail_retry'),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
