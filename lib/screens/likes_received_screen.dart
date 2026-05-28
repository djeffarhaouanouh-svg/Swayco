import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/device_id.dart';
import '../services/like_api.dart';
import '../services/profile_api.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

/// Lists every Supabase user that has liked the current account, newest
/// first. Tapping a row opens that user's profile (read-only) so the
/// recipient can act on the like (chat / block / etc.).
class LikesReceivedScreen extends StatefulWidget {
  const LikesReceivedScreen({super.key});

  @override
  State<LikesReceivedScreen> createState() => _LikesReceivedScreenState();
}

class _LikesReceivedScreenState extends State<LikesReceivedScreen> {
  bool _loading = true;
  List<RemoteProfile> _likers = const [];
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = WebPoll.every(
      const Duration(seconds: 15),
      () => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final uid = await DeviceId.getOrCreate();
    final list = await LikeApi.fetchLikersOf(uid);
    if (!mounted) return;
    setState(() {
      _likers = list;
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
          AppStrings.t('who_liked_me'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: SC.accent))
          : _likers.isEmpty
              ? const _EmptyState()
              : RefreshIndicator(
                  color: SC.accent,
                  backgroundColor: SC.bubbleIn,
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _likers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final p = _likers[i];
                      return _LikerRow(
                        profile: p,
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => ProfileScreen(userId: p.id),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _LikerRow extends StatelessWidget {
  const _LikerRow({required this.profile, required this.onTap});
  final RemoteProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.bubbleIn,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF2A3942)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              ProfileAvatar(
                displayName: profile.displayName,
                avatarUrl: profile.avatarUrl,
                avatarColorHex: profile.avatarColor,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.displayName.isEmpty ? 'â€”' : profile.displayName,
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (profile.handle.isNotEmpty)
                      Text(
                        '@${profile.handle}',
                        style: const TextStyle(
                          color: SC.textMuted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.favorite,
                  color: Color(0xFFFF3B5C), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite_border,
                size: 56, color: SC.textMuted),
            const SizedBox(height: 14),
            Text(
              AppStrings.t('no_one_liked_yet'),
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.t('like_explainer'),
              textAlign: TextAlign.center,
              style: const TextStyle(
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
