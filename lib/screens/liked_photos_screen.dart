import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/like_api.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

/// One liked photo + the profile it belongs to.
typedef _LikedItem = ({String photoUrl, RemoteProfile owner});

/// List of the photos the current user has liked — rendered like the
/// reaction rows (avatar + name on the left, the liked photo as a thumbnail
/// on the right). Tapping a row opens that person's profile and the photo.
/// Reached from Settings → Confidentialité.
class LikedPhotosScreen extends StatefulWidget {
  const LikedPhotosScreen({super.key});

  @override
  State<LikedPhotosScreen> createState() => _LikedPhotosScreenState();
}

class _LikedPhotosScreenState extends State<LikedPhotosScreen> {
  bool _loading = true;
  List<_LikedItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = await DeviceId.getOrCreate();
    // Two like paths, both keyed by the device id:
    //   1. LikeApi likes — the ❤ on a peer's profile photo.
    //   2. ❤️ reactions sent on the Discover feed (stored as messages).
    // Each carries the photo's owner, so we can show the avatar + name and
    // link to the right profile.
    final results = await Future.wait([
      LikeApi.fetchMyLikedItems(uid),
      ChatApi.fetchMyHeartedItems(uid),
    ]);
    final liked = results[0];
    final hearted = results[1];
    // Dedupe by photo URL, remembering its owner.
    final ownerByPhoto = <String, String>{};
    for (final it in [...liked, ...hearted]) {
      ownerByPhoto.putIfAbsent(it.photoUrl, () => it.ownerId);
    }
    final ownerIds = ownerByPhoto.values.toSet().toList(growable: false);
    final profiles =
        ownerIds.isEmpty ? const <RemoteProfile>[] : await ProfileApi.fetchByIds(ownerIds);
    final byId = {for (final p in profiles) p.id: p};
    final items = <_LikedItem>[];
    for (final e in ownerByPhoto.entries) {
      final owner = byId[e.value];
      if (owner == null) continue;
      items.add((photoUrl: e.key, owner: owner));
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  /// Open the photo owner's profile, then surface the photo full-screen on
  /// top — so the user lands on the person AND the exact photo they liked.
  void _open(_LikedItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(userId: item.owner.id),
      ),
    );
    showPhotoViewer(
      context,
      photos: [item.photoUrl],
      index: 0,
      viewerMode: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      appBar: AppBar(
        backgroundColor: SC.bg,
        foregroundColor: SC.textPrimary,
        elevation: 0,
        title: Text(
          AppStrings.t('settings_liked_photos'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: SC.accent))
          : _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.favorite_border_rounded,
                      size: 48,
                      color: SC.textMuted.withValues(alpha: 0.6),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      AppStrings.t('liked_photos_empty'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: SC.textMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              color: SC.accent,
              backgroundColor: SC.menu,
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) => GlassContainer(
                  borderRadius: BorderRadius.circular(24),
                  padding: const EdgeInsets.all(6),
                  child: _LikedRow(
                    item: _items[i],
                    onTap: () => _open(_items[i]),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A single liked-photo row: avatar + name on the left, the liked photo as a
/// thumbnail on the right (same footprint as the reaction-row emoji).
class _LikedRow extends StatelessWidget {
  const _LikedRow({required this.item, required this.onTap});

  final _LikedItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = item.owner;
    final name = o.displayName.isNotEmpty
        ? o.displayName
        : (o.handle.isNotEmpty ? '@${o.handle}' : AppStrings.t('chat_no_name'));
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ProfileAvatar(
                displayName: o.displayName,
                avatarUrl: o.avatarUrl,
                fallbackUrl: o.fallbackPhotoUrl,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  item.photoUrl,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 46,
                    height: 46,
                    color: SC.menu,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      color: SC.textMuted,
                      size: 18,
                    ),
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
