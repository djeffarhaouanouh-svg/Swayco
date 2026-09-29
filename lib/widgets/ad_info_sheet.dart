import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

const _kSeenKey = 'ad_info_sheet_seen';

/// Shows, ONCE per install, the sheet explaining how to skip a full-screen
/// ad. Called right after the first interstitial the user actually watched.
Future<void> showAdInfoSheetOnce(BuildContext context) async {
  try {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_kSeenKey) ?? false) return;
    await p.setBool(_kSeenKey, true);
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _AdInfoSheet(),
  );
}

class _AdInfoSheet extends StatelessWidget {
  const _AdInfoSheet();

  static const _surface = Color(0xFF1A1A1D);
  static const _chip = Color(0xFF2A2A2E);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _chip),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    color: _chip,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white70,
                    size: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              AppStrings.t('ad_info_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppStrings.t('ad_info_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textMuted,
                fontSize: 14,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SkipIcon(Icons.keyboard_double_arrow_right_rounded),
                _SkipIcon(Icons.last_page_rounded),
                _SkipIcon(Icons.close_rounded),
                _SkipIcon(Icons.skip_next_rounded),
              ],
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: const Color(0xFF0B0B0C),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
                child: const Text(
                  'OK',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkipIcon extends StatelessWidget {
  const _SkipIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _AdInfoSheet._chip,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}
