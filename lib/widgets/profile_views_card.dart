import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/nav_tab.dart';
import '../services/profile_views_api.dart';
import '../theme/swayco_theme.dart';
import 'popup_kit.dart' show popupDisplay;
import 'profile_avatar.dart';

/// « Vues du profil » sur mon profil : les dernières têtes, le nombre de la
/// semaine, les nouvelles en jaune. Un tap ouvre la liste.
class ProfileViewsCard extends StatefulWidget {
  const ProfileViewsCard({super.key, required this.onOpen});

  /// Ouvre la liste ; la future se termine au retour.
  final Future<void> Function() onOpen;

  @override
  State<ProfileViewsCard> createState() => _ProfileViewsCardState();
}

class _ProfileViewsCardState extends State<ProfileViewsCard> {
  List<ProfileView>? _views;
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
      final views = await ProfileViewsApi.thisWeek();
      final seen = await ProfileViewsApi.lastSeen();
      if (!mounted) return;
      setState(() {
        _views = views;
        _fresh = views.where((v) => v.at.isAfter(seen)).length;
      });
    } catch (e) {
      // Table absente ou réseau : la carte reste cachée plutôt que d'annoncer
      // un faux « 0 ».
      debugPrint('profile views card: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final views = _views;
    if (views == null) return const SizedBox.shrink();
    final light = SC.light;
    final faces = views.take(3).toList();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await widget.onOpen();
        if (mounted) await _load();
      },
      child: Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: light ? const Color(0xFFF8F9FC) : null,
          gradient: light
              ? null
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x1AFFFFFF), Color(0x0AFFFFFF)],
                ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: light ? const Color(0x1A04123A) : const Color(0x29FFFFFF),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: faces.isEmpty ? 34 : 34 + 22.0 * (faces.length - 1),
              height: 34,
              child: faces.isEmpty
                  ? Icon(Icons.visibility_outlined,
                      size: 26, color: SC.textMuted)
                  : Stack(
                      children: [
                        for (final (i, v) in faces.indexed)
                          Positioned(
                            left: 22.0 * i,
                            child: Container(
                              padding: const EdgeInsets.all(1.5),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: light
                                    ? const Color(0xFFF8F9FC)
                                    : const Color(0xFF1B1D2E),
                              ),
                              child: ProfileAvatar(
                                displayName: v.profile.displayName,
                                avatarUrl: v.profile.bestAvatarUrl,
                                size: 31,
                              ),
                            ),
                          ),
                      ],
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
                    AppStrings.t('profile_views_week',
                        args: {'n': '${views.length}'}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: SC.textPrimary.withValues(alpha: 0.7),
                      fontSize: 12.5,
                    ),
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
                  color: const Color(0xFFF4FF1F),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '$_fresh',
                  style: const TextStyle(
                    color: Color(0xFF04123A),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded,
                size: 22, color: SC.textPrimary.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}
