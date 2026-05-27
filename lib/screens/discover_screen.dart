import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/languages.dart';
import '../services/like_api.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/mesh_background.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  // Real Supabase profiles, hydrated from ProfileApi.fetchDiscoverFeed at
  // bootstrap. Excludes me, anyone I've blocked / who's blocked me, and
  // accepted friends.
  List<RemoteProfile> _profiles = const <RemoteProfile>[];
  bool _feedLoading = true;

  int _topIndex = 0;
  // Profile ids I've already liked — heart renders filled for these.
  // Hydrated from Supabase on bootstrap so the state survives restarts /
  // multi-device; mutated optimistically on every tap, written through
  // LikeApi.like / LikeApi.unlike.
  Set<String> _likedIds = <String>{};

  // TikTok-style vertical pager. Swipe up = next profile, swipe down =
  // previous. Snapping + the slide animation are handled by PageView.
  final PageController _pageController = PageController();

  Timer? _pollTimer;
  String _myId = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();
    // Web: periodically refresh the likes I've given so a heart that
    // got optimistically toggled on a different device converges within
    // ~10s. The feed itself is not re-fetched (it'd reset the swipe
    // position) — only the lightweight signal queries.
    _pollTimer = WebPoll.every(
      const Duration(seconds: 10),
      _refreshLiveSignals,
    );
  }

  /// Lightweight refresh: re-pulls likes I've given. Keeps the card
  /// stack and `_topIndex` exactly where they are.
  Future<void> _refreshLiveSignals() async {
    if (_myId.isEmpty || !isSupabaseReady) return;
    try {
      final liked = await LikeApi.fetchMyLikedIds(_myId);
      if (!mounted) return;
      setState(() => _likedIds = liked);
    } catch (_) {
      // Polling errors are non-fatal — next tick will retry.
    }
  }

  Future<void> _bootstrap() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    if (!isSupabaseReady || id.isEmpty) {
      setState(() => _feedLoading = false);
      return;
    }
    try {
      final liked = await LikeApi.fetchMyLikedIds(id);
      final feed = await ProfileApi.fetchDiscoverFeed(myId: id);
      if (!mounted) return;
      setState(() {
        _likedIds = liked;
        _profiles = feed;
        _feedLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _feedLoading = false);
    }
  }

  /// Toggle a like on [profileId]. Optimistic local flip + DB write
  /// through LikeApi; on error roll back so the heart matches the truth.
  Future<void> _toggleLikeOnProfile(String profileId) async {
    if (_myId.isEmpty || profileId.isEmpty) return;
    final wasLiked = _likedIds.contains(profileId);
    setState(() {
      if (wasLiked) {
        _likedIds = {..._likedIds}..remove(profileId);
      } else {
        _likedIds = {..._likedIds, profileId};
      }
    });
    try {
      if (wasLiked) {
        await LikeApi.unlike(likerId: _myId, likedId: profileId);
      } else {
        await LikeApi.like(likerId: _myId, likedId: profileId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (wasLiked) {
          _likedIds = {..._likedIds, profileId};
        } else {
          _likedIds = {..._likedIds}..remove(profileId);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('like_save_failed'))),
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  /// TikTok-style "next profile" — slides the next card up into view.
  /// Wired to the explicit Send button (after sending the 👋) and any
  /// other affordance that wants to programmatically advance.
  void _advance() {
    if (!_pageController.hasClients) return;
    if (_topIndex >= _profiles.length) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// TikTok-style "previous profile" — slides the previous card down
  /// into view. Wired to the circular back arrow on each card.
  void _back() {
    if (!_pageController.hasClients || _topIndex <= 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Sends a "👋 Coucou !" message to the visible profile via ChatApi.
  /// The conversation id is the same deterministic dm-{a}-{b} key the
  /// chat list uses, so the message lands directly in their thread.
  Future<void> _sendHello(RemoteProfile peer) async {
    if (_myId.isEmpty || peer.id.isEmpty) return;
    try {
      final local = await UserPrefs.loadProfile();
      final myProfile =
          isSupabaseReady ? await ProfileApi.fetchById(_myId) : null;
      final myName = (myProfile?.displayName.trim().isNotEmpty == true)
          ? myProfile!.displayName
          : (local?.firstName.trim() ?? '');
      final myLang = (myProfile?.language.trim().isNotEmpty == true)
          ? myProfile!.language
          : (local?.sourceLang ?? '');
      final ids = [_myId, peer.id]..sort();
      final convId = 'dm-${ids[0]}-${ids[1]}';
      await ChatApi.sendMessage(
        conversationId: convId,
        senderId: _myId,
        senderName: myName,
        recipientId: peer.id,
        body: '👋 Coucou !',
        language: myLang,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('👋 envoyé à ${peer.displayName}'),
          duration: const Duration(seconds: 2),
          backgroundColor: SC.bubbleIn,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Envoi échoué : $e')),
      );
    }
  }

  Future<void> _reset() async {
    if (_myId.isEmpty) {
      setState(() => _topIndex = 0);
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      return;
    }
    setState(() {
      _topIndex = 0;
      _feedLoading = true;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(0);
    final feed = await ProfileApi.fetchDiscoverFeed(myId: _myId);
    if (!mounted) return;
    setState(() {
      _profiles = feed;
      _feedLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SC.bg,
      // Cards extend behind the floating bottom nav for the TikTok-style
      // full-bleed look (nav stays interactive on top via RootShell's
      // Stack). extendBody achieves the same on the top edge w.r.t. the
      // status bar — the photo bleeds under it through MeshBackground.
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: MeshBackground(
        child: _feedLoading
            ? const Center(
                child: CircularProgressIndicator(color: SC.accent),
              )
            : _buildStack(),
      ),
    );
  }

  Widget _buildStack() {
    // Each PageView page renders one profile card sized at 3:4 portrait,
    // capped at 460 wide on desktop so the photo isn't stretched into
    // the full width of a 1900-px viewport. PageView handles the
    // vertical snap + slide animation natively — swipe up reveals the
    // next profile, swipe down brings the previous one back.
    //
    // An extra page after the last profile shows the "all caught up"
    // empty state so the user scrolls into it the same way they scroll
    // between profiles.
    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      itemCount: _profiles.length + 1,
      onPageChanged: (i) => setState(() => _topIndex = i),
      itemBuilder: (ctx, i) {
        if (i >= _profiles.length) {
          return _Empty(onReset: _reset);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: _ProfileCard(
                  profile: _profiles[i],
                  onAdd: () {
                    _sendHello(_profiles[i]);
                    _advance();
                  },
                  onBack: i > 0 ? _back : null,
                  liked: _likedIds.contains(_profiles[i].id),
                  onToggleLike: () =>
                      _toggleLikeOnProfile(_profiles[i].id),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.onAdd,
    this.onBack,
    this.liked = false,
    this.onToggleLike,
  });

  final RemoteProfile profile;
  final VoidCallback onAdd;
  /// When non-null, a circular back arrow is rendered at the top-left of the
  /// card. Tapping it returns to the previous profile.
  final VoidCallback? onBack;
  final bool liked;
  /// When non-null, a heart button is rendered to the right of "Envoyer 👋".
  /// Tap toggles liked state.
  final VoidCallback? onToggleLike;

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(profile.language);
    final flag = lang?.flag ?? '';
    final photoUrl = profile.discoverPhotoUrl.isNotEmpty
        ? profile.discoverPhotoUrl
        : profile.avatarUrl;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: SC.meshCyan.withValues(alpha: 0.30),
            blurRadius: 60,
            offset: const Offset(0, 30),
          ),
        ],
      ),
      child: ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: SC.bubbleIn),
          if (photoUrl.isNotEmpty)
            Image.network(
              photoUrl,
              fit: BoxFit.cover,
              // Centre crop — keeps the face roughly in the middle of the
              // card whether the source is portrait, square, or landscape.
              alignment: Alignment.center,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.10),
                    Colors.black.withValues(alpha: 0.85),
                  ],
                  stops: const [0.45, 0.65, 1.0],
                ),
              ),
            ),
          ),
          if (onBack != null)
            Positioned(
              top: 14,
              left: 14,
              child: _BackButton(onTap: onBack!),
            ),
          Positioned(
            left: 22,
            right: 22,
            bottom: 22,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Left side: name + flag + bio + send button stacked vertically.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: Text(
                              profile.displayName.isEmpty
                                  ? '—'
                                  : profile.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SCText.h1.copyWith(
                                fontSize: 32,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (flag.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(flag,
                                  style: const TextStyle(fontSize: 22)),
                            ),
                          ],
                        ],
                      ),
                      if (profile.bio.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          profile.bio,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _AddButton(onTap: onAdd),
                    ],
                  ),
                ),
                // Right rail: 4 random reaction emojis (ghosted until tapped)
                // stacked above the heart. Skipped together with the heart
                // for background-deck instances where interaction is off.
                if (onToggleLike != null) ...[
                  const SizedBox(width: 12),
                  _ReactionRail(
                    heart: _LikeHeart(
                        liked: liked, onTap: onToggleLike!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _LikeHeart extends StatelessWidget {
  const _LikeHeart({required this.liked, required this.onTap});
  final bool liked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF3B5C);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: liked
              ? red.withValues(alpha: 0.18)
              : Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: liked ? red : Colors.white.withValues(alpha: 0.20),
            width: liked ? 2 : 1,
          ),
        ),
        child: Icon(
          liked ? Icons.favorite : Icons.favorite_border,
          size: liked ? 26 : 22,
          color: liked ? red : Colors.white,
        ),
      ),
    );
  }
}

/// Vertical reaction rail rendered on the right side of a profile card.
/// The same 4 ghosted "send-a-vibe" emojis are shown above [heart] on
/// every card; each is dim by default and fills in when tapped.
class _ReactionRail extends StatelessWidget {
  const _ReactionRail({required this.heart});

  final Widget heart;

  // Fixed across all cards so users learn the rail by muscle memory.
  static const _emojis = <String>['🔥', '✨', '💯', '😍'];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final emoji in _emojis) ...[
          _ReactionEmojiButton(emoji: emoji),
          const SizedBox(height: 10),
        ],
        heart,
      ],
    );
  }
}

/// One reaction-rail emoji — mirrors [_LikeHeart] exactly so the rail
/// feels uniform with the heart at its bottom: same 48 px circle, same
/// dark glass chip when idle, same accented border when active, same
/// 160 ms animation. State is local — refreshes when the parent card
/// rebuilds (e.g. after swiping to a new profile).
class _ReactionEmojiButton extends StatefulWidget {
  const _ReactionEmojiButton({required this.emoji});

  final String emoji;

  @override
  State<_ReactionEmojiButton> createState() => _ReactionEmojiButtonState();
}

class _ReactionEmojiButtonState extends State<_ReactionEmojiButton> {
  bool _tapped = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _tapped = !_tapped),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _tapped
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white
                .withValues(alpha: _tapped ? 0.85 : 0.20),
            width: _tapped ? 2 : 1,
          ),
        ),
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 160),
            style: TextStyle(
              fontSize: _tapped ? 24 : 20,
              color: Colors.white
                  .withValues(alpha: _tapped ? 1.0 : 0.45),
            ),
            child: Text(widget.emoji),
          ),
        ),
      ),
    );
  }
}

/// "Envoyer 👋" — the emoji scales up briefly and the device gives a short
/// haptic tap on press. Parent then advances to the next card.
class _AddButton extends StatefulWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _rotate;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    // Scale: 1 → 1.7 → 1, with overshoot.
    _scale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.7)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 40),
      TweenSequenceItem(
          tween: Tween(begin: 1.7, end: 1.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 60),
    ]).animate(_ctrl);
    // Wave: -15° → +15° → -10° → 0 over the burst.
    _rotate = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -0.26), weight: 25),
      TweenSequenceItem(tween: Tween(begin: -0.26, end: 0.26), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 0.26, end: -0.17), weight: 25),
      TweenSequenceItem(tween: Tween(begin: -0.17, end: 0.0), weight: 25),
    ]).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onPress() {
    HapticFeedback.mediumImpact();
    _ctrl.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _onPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Strip the 👋 from the i18n string so we can animate it on
              // its own next to the localised verb.
              Text(
                '${AppStrings.t('send_emoji').replaceAll('👋', '').trim()} ',
                style: const TextStyle(
                  color: SC.bg,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, _) => Transform.rotate(
                  angle: _rotate.value,
                  child: Transform.scale(
                    scale: _scale.value,
                    child: const Text('👋', style: TextStyle(fontSize: 16)),
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

/// "Rewind" button — top-left of the top card. Curved U-turn arrow,
/// styled like the Chercher / Filtres pills in the header (same gray
/// background, same height). Shown only when there's a previous profile.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      icon: Icons.replay,
      size: 36,
      iconSize: 18,
      onTap: onTap,
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onReset});
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: SC.bubbleIn,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.favorite_border,
                  color: SC.textMuted, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('discover_done'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SC.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.refresh, color: SC.accent),
              label: Text(
                AppStrings.t('restart'),
                style: const TextStyle(color: SC.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
