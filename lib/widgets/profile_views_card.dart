import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/nav_tab.dart';
import '../services/profile_views_api.dart';
import '../services/revenue_cat.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart' show popupDisplay;
import 'profile_views_kit.dart';

/// « Vues du profil » sur mon profil : les dernières têtes (floutées en
/// gratuit), le nombre de la semaine, les nouvelles en jaune. Un tap ouvre
/// l'écran.
class ProfileViewsCard extends StatefulWidget {
  const ProfileViewsCard({super.key, required this.onOpen});

  /// Ouvre l'écran ; la future se termine au retour.
  final Future<void> Function() onOpen;

  @override
  State<ProfileViewsCard> createState() => _ProfileViewsCardState();
}

class _ProfileViewsCardState extends State<ProfileViewsCard> {
  ProfileViewsData? _data;
  int _fresh = 0;

  @override
  void initState() {
    super.initState();
    NavTab.index.addListener(_onTab);
    _load();
  }

  @override
  void dispose() {
    NavTab.index.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (NavTab.index.value == NavTab.profile) _load();
  }

  Future<void> _load() async {
    try {
      final data = await ProfileViewsApi.load();
      final seen = await ProfileViewsApi.lastSeen();
      if (!mounted) return;
      setState(() {
        _data = data;
        _fresh = data.newSince(seen);
      });
    } catch (e) {
      // Table absente ou réseau : la carte reste cachée plutôt que d'annoncer
      // un faux « 0 ».
      debugPrint('profile views card: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final faces = data.visitors(7, now).take(3).toList();
    final muted = SC.textPrimary.withValues(alpha: 0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await widget.onOpen();
        if (mounted) await _load();
      },
      child: Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(14),
        decoration: viewsCardDecoration(),
        child: Row(
          children: [
            SizedBox(
              width: faces.isEmpty ? 34 : 34 + 22.0 * (faces.length - 1),
              height: 34,
              child: faces.isEmpty
                  ? Icon(
                      data.settings.history
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 26,
                      color: SC.textMuted,
                    )
                  : ValueListenableBuilder<bool>(
                      valueListenable: RevenueCat.proActive,
                      builder: (_, pro, _) => Stack(
                        children: [
                          for (final (i, v) in faces.indexed)
                            Positioned(
                              left: 22.0 * i,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: SC.light
                                      ? Colors.white
                                      : const Color(0xFF1B1B1F),
                                ),
                                child: VisitorFace(
                                  profile: v.profile,
                                  size: 30,
                                  blurred: !pro,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStrings.t('profile_views_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: popupDisplay(
                      fontSize: 14,
                      letterSpacing: -0.3,
                      color: SC.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.settings.history
                        ? AppStrings.t('profile_views_week',
                            args: {'n': '${data.count(7, now)}'})
                        : AppStrings.t('profile_views_off'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            if (_fresh > 0) ...[
              const SizedBox(width: 8),
              Container(
                height: 24,
                constraints: const BoxConstraints(minWidth: 24),
                padding: const EdgeInsets.symmetric(horizontal: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kViewsYellow,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '$_fresh',
                  style: const TextStyle(
                    color: kViewsInk,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 22, color: muted),
          ],
        ),
      ),
    );
  }
}
