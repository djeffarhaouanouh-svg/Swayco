import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/profile_views_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/load_failed_view.dart';
import '../widgets/mesh_background.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/round_flag.dart';
import 'profile_screen.dart';

/// « Vues du profil » : qui a ouvert mon profil ces 7 derniers jours.
class ProfileViewsScreen extends StatefulWidget {
  const ProfileViewsScreen({super.key});

  @override
  State<ProfileViewsScreen> createState() => _ProfileViewsScreenState();
}

class _ProfileViewsScreenState extends State<ProfileViewsScreen> {
  List<ProfileView>? _views;
  DateTime? _seenBefore;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final seen = await ProfileViewsApi.lastSeen();
      final views = await ProfileViewsApi.thisWeek();
      await ProfileViewsApi.markSeen();
      if (!mounted) return;
      setState(() {
        _seenBefore ??= seen;
        _views = views;
        _failed = false;
      });
    } catch (e) {
      debugPrint('profile views load failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final views = _views;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight + 12;
    final Widget body;
    if (_failed && views == null) {
      body = LoadFailedView(onRetry: _load);
    } else if (views == null) {
      body = Center(child: CircularProgressIndicator(color: SC.accentFg));
    } else if (views.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.visibility_outlined, size: 56, color: SC.textMuted),
              const SizedBox(height: 14),
              Text(
                AppStrings.t('profile_views_empty'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: SC.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      body = RefreshIndicator(
        color: SC.accentFg,
        backgroundColor: SC.menu,
        onRefresh: _load,
        child: ListView.separated(
          padding: EdgeInsets.fromLTRB(16, top, 16, 24),
          itemCount: views.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final p = views[i].profile;
            final fresh =
                _seenBefore != null && views[i].at.isAfter(_seenBefore!);
            final name = p.displayName.isEmpty ? '—' : p.displayName;
            final country = p.country.trim();
            return Material(
              color: SC.glassStrong,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: SC.glassBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfileScreen(userId: p.id),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    children: [
                      ProfileAvatar(
                        displayName: p.displayName,
                        avatarUrl: p.bestAvatarUrl,
                        size: 52,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              p.age != null ? '$name, ${p.age}' : name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: SC.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (country.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  RoundFlag(
                                    country: country,
                                    language: p.language,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      country,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: SC.textMuted,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (fresh)
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: SC.accentFg,
                          ),
                        ),
                      Icon(Icons.chevron_right_rounded, color: SC.textMuted),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
    return Scaffold(
      backgroundColor: SC.bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: SC.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(AppStrings.t('profile_views_title'), style: SCText.h3),
      ),
      body: MeshBackground(child: body),
    );
  }
}
