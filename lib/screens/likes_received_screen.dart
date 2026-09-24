import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../services/device_id.dart';
import '../services/like_api.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/likes_lock.dart';
import '../widgets/profile_avatar.dart';
import 'profile_screen.dart';

/// Lists every Supabase user that has liked the current account, newest
/// first. Without Pro each liker's PDP is blurred and the name hidden
/// ([LikesLock]); tapping a revealed row opens that user's profile.
class LikesReceivedScreen extends StatefulWidget {
  const LikesReceivedScreen({super.key});

  @override
  State<LikesReceivedScreen> createState() => _LikesReceivedScreenState();
}

class _LikesReceivedScreenState extends State<LikesReceivedScreen> {
  bool _loading = true;
  List<RemoteProfile> _likers = const [];
  LikesLock? _lock;
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
    final results = await Future.wait<Object?>([
      LikeApi.fetchLikersOf(uid),
      LikesLock.load(uid),
    ]);
    if (!mounted) return;
    setState(() {
      _likers = results[0] as List<RemoteProfile>;
      _lock = results[1] as LikesLock;
      _loading = false;
    });
  }

  void _openOrUnlock(RemoteProfile p) {
    final lock = _lock;
    if (lock == null) return;
    if (lock.isRevealed(p.id)) {
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: p.id)),
      );
      return;
    }
    showLikesUnlockSheet(
      context,
      myId: lock.myId,
      profile: p,
      onRevealed: () {
        if (mounted) setState(() => lock.unlocked.add(p.id));
      },
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
          AppStrings.t('who_liked_me'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: SC.accent))
          : _likers.isEmpty
          ? const _EmptyState()
          : ValueListenableBuilder<bool>(
              valueListenable: RevenueCat.proActive,
              builder: (context, _, _) => RefreshIndicator(
                color: SC.accent,
                backgroundColor: SC.menu,
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: _likers.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final p = _likers[i];
                    return _LikerRow(
                      profile: p,
                      revealed: _lock?.isRevealed(p.id) ?? false,
                      onTap: () => _openOrUnlock(p),
                    );
                  },
                ),
              ),
            ),
    );
  }
}

class _LikerRow extends StatelessWidget {
  const _LikerRow({
    required this.profile,
    required this.revealed,
    required this.onTap,
  });

  final RemoteProfile profile;
  final bool revealed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.menu,
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
              if (revealed)
                ProfileAvatar(
                  displayName: profile.displayName,
                  avatarUrl: profile.avatarUrl,
                  fallbackUrl: profile.fallbackPhotoUrl,
                  size: 44,
                )
              else
                BlurredAvatar(profile: profile, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      !revealed
                          ? AppStrings.t('likes_someone')
                          : profile.displayName.isEmpty
                          ? '—'
                          : profile.displayName,
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (revealed && profile.handle.isNotEmpty)
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
              const Icon(Icons.favorite, color: Color(0xFFFF3B5C), size: 20),
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
            const Icon(Icons.favorite_border, size: 56, color: SC.textMuted),
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
