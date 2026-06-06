import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/like_api.dart';
import '../theme/swayco_theme.dart';
import 'profile_screen.dart';

/// Grid of the photos the current user has liked. Tap one to open it
/// full-screen. Reached from Settings → Confidentialité.
class LikedPhotosScreen extends StatefulWidget {
  const LikedPhotosScreen({super.key});

  @override
  State<LikedPhotosScreen> createState() => _LikedPhotosScreenState();
}

class _LikedPhotosScreenState extends State<LikedPhotosScreen> {
  bool _loading = true;
  List<String> _photos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = await DeviceId.getOrCreate();
    // Two like paths feed this page, both keyed by the device id:
    //   1. LikeApi likes — the ❤ on a peer's profile photo.
    //   2. ❤️ reactions sent on the Discover feed (stored as messages).
    // Union them so every photo I hearted, wherever I did it, shows up here.
    final results = await Future.wait([
      LikeApi.fetchMyLikedPhotos(uid),
      ChatApi.fetchMyOutgoingPhotoReactions(uid),
    ]);
    final liked = results[0] as Set<String>;
    final reactions = results[1] as Map<String, Set<String>>;
    final hearted = <String>{
      for (final e in reactions.entries)
        if (e.value.any((emoji) => emoji.contains('❤'))) e.key,
    };
    if (!mounted) return;
    setState(() {
      _photos = <String>{...liked, ...hearted}.toList();
      _loading = false;
    });
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
          : _photos.isEmpty
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
              backgroundColor: SC.bubbleIn,
              onRefresh: _load,
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 3 / 4,
                ),
                itemCount: _photos.length,
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => showPhotoViewer(
                    context,
                    photos: _photos,
                    index: i,
                    viewerMode: true,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      _photos[i],
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: SC.bubbleIn,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.broken_image_outlined,
                          color: SC.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
