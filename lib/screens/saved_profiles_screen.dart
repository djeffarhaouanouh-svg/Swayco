import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/friendly_error.dart';
import '../services/profile_api.dart';
import '../services/saved_profiles_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/load_failed_view.dart';
import '../widgets/mesh_background.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/round_flag.dart';
import 'profile_screen.dart';

/// Paramètres → « Profils enregistrés » : les profils gardés avec le
/// marque-page. Un tap ouvre le profil, le marque-page le retire.
class SavedProfilesScreen extends StatefulWidget {
  const SavedProfilesScreen({super.key});

  @override
  State<SavedProfilesScreen> createState() => _SavedProfilesScreenState();
}

class _SavedProfilesScreenState extends State<SavedProfilesScreen> {
  List<RemoteProfile>? _saved;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    SavedProfilesApi.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    SavedProfilesApi.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await SavedProfilesApi.fetch();
      if (!mounted) return;
      setState(() {
        _saved = list;
        _failed = false;
      });
    } catch (e) {
      debugPrint('saved profiles load failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _remove(RemoteProfile p) async {
    final before = _saved;
    setState(() {
      _saved = [for (final s in before ?? const <RemoteProfile>[])
        if (s.id != p.id) s];
    });
    try {
      await SavedProfilesApi.setSaved(p.id, false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saved = before);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight + 12;
    final Widget body;
    if (_failed && saved == null) {
      body = LoadFailedView(onRetry: _load);
    } else if (saved == null) {
      body = Center(child: CircularProgressIndicator(color: SC.accentFg));
    } else if (saved.isEmpty) {
      body = const _Empty();
    } else {
      body = RefreshIndicator(
        color: SC.accentFg,
        backgroundColor: SC.menu,
        onRefresh: _load,
        child: ListView.separated(
          padding: EdgeInsets.fromLTRB(16, top, 16, 24),
          itemCount: saved.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _Row(
            profile: saved[i],
            onOpen: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ProfileScreen(userId: saved[i].id),
              ),
            ),
            onRemove: () => _remove(saved[i]),
          ),
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
        title: Text(
          AppStrings.t('saved_profiles_title'),
          style: SCText.h3,
        ),
      ),
      body: MeshBackground(child: body),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.profile,
    required this.onOpen,
    required this.onRemove,
  });

  final RemoteProfile profile;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = profile;
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
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
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
              IconButton(
                tooltip: AppStrings.t('peer_unsave'),
                onPressed: onRemove,
                icon: Icon(Icons.bookmark_rounded, color: SC.accentFg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border_rounded, size: 56, color: SC.textMuted),
            const SizedBox(height: 14),
            Text(
              AppStrings.t('saved_profiles_empty'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('saved_profiles_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SC.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
