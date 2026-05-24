import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/voice_message_api.dart';

import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/languages.dart';
import '../services/like_api.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/stripe_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/whatsapp_call_theme.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import 'chat_thread_screen.dart';
import 'friends_list_screen.dart';
import 'likes_received_screen.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart';

/// Profile view. Two modes:
///
///   * `userId` is null (default): "my own" profile — editable, shows the
///     Free Account / Premium card, Edit + Paramètres buttons.
///   * `userId` is set: another user's profile, viewed read-only. Camera /
///     edit affordances are hidden, premium card and the call-language
///     warning are dropped (private to me), and the action row becomes
///     Bloquer / Débloquer instead of Edit / Paramètres.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.userId});

  /// When non-null, render the profile of the given Supabase auth user id
  /// in read-only "viewer" mode rather than my own profile.
  final String? userId;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with WidgetsBindingObserver {
  String _deviceId = '';
  RemoteProfile? _remote;
  ProfileSnapshot? _local;
  FriendshipCounts _counts = const FriendshipCounts(followers: 0, following: 0);
  int _likesCount = 0;
  bool _loading = true;
  // Viewer-mode only: am I currently blocking the displayed user?
  bool _peerBlocked = false;
  // Viewer-mode only: have I liked the displayed user? Drives the heart
  // overlay on the peer's Discover photo.
  bool _iLikePeer = false;
  // Viewer-mode only: directional follow state with the displayed user.
  // `_peerFollowsMe` → they added me; `_iFollowPeer` → I added them.
  bool _peerFollowsMe = false;
  bool _iFollowPeer = false;
  Timer? _pollTimer;

  bool get _isViewingOther => widget.userId != null;
  String get _targetId => widget.userId ?? _deviceId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    // Web build: poll for fresh counts / likes / bio every 12s so changes
    // made elsewhere (a new follower, an incoming like) appear without a
    // manual refresh.
    _pollTimer = WebPoll.every(
      const Duration(seconds: 12),
      () => _reload(silent: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
    }
  }

  Future<void> _reload({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() => _loading = true);
    }
    final deviceId = await DeviceId.getOrCreate();
    final targetId = widget.userId ?? deviceId;
    // Local prefs only matter for my own profile (offline fallback). When
    // viewing someone else there's no local cache to consult.
    final local = _isViewingOther ? null : await UserPrefs.loadProfile();
    final remote =
        isSupabaseReady ? await ProfileApi.fetchById(targetId) : null;
    final counts = isSupabaseReady
        ? await FriendshipApi.countsFor(targetId)
        : const FriendshipCounts(followers: 0, following: 0);
    // Likes received are only meaningful (and visible) on my own profile.
    // The peer's count would leak who liked them.
    final likes = !_isViewingOther && isSupabaseReady
        ? await LikeApi.countLikersOf(targetId)
        : 0;
    final blocked = _isViewingOther && isSupabaseReady && deviceId.isNotEmpty
        ? await BlockApi.isBlocked(blockerId: deviceId, otherId: targetId)
        : false;
    // In viewer mode we also need the "do I like this peer?" bit so the
    // heart overlay renders in the right state on first paint.
    bool iLike = false;
    if (_isViewingOther && isSupabaseReady && deviceId.isNotEmpty) {
      try {
        final myLikes = await LikeApi.fetchMyLikedIds(deviceId);
        iLike = myLikes.contains(targetId);
      } catch (_) {}
    }
    // Directional follow state — drives the "Follow back" button.
    var peerFollowsMe = false;
    var iFollowPeer = false;
    if (_isViewingOther && isSupabaseReady && deviceId.isNotEmpty) {
      final rel = await FriendshipApi.directionalWith(
        meId: deviceId,
        peerId: targetId,
      );
      peerFollowsMe = rel.peerFollowsMe;
      iFollowPeer = rel.iFollowPeer;
    }
    if (!mounted) return;
    setState(() {
      _deviceId = deviceId;
      _local = local;
      _remote = remote;
      _counts = counts;
      _likesCount = likes;
      _peerBlocked = blocked;
      _iLikePeer = iLike;
      _peerFollowsMe = peerFollowsMe;
      _iFollowPeer = iFollowPeer;
      _loading = false;
    });
  }

  /// Optimistic like/unlike of the displayed peer (viewer mode). Roll back
  /// the local flag if the DB write fails.
  Future<void> _togglePeerLike() async {
    if (!_isViewingOther || _deviceId.isEmpty || _targetId.isEmpty) return;
    final wasLiked = _iLikePeer;
    setState(() => _iLikePeer = !wasLiked);
    try {
      if (wasLiked) {
        await LikeApi.unlike(likerId: _deviceId, likedId: _targetId);
      } else {
        await LikeApi.like(likerId: _deviceId, likedId: _targetId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _iLikePeer = wasLiked);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'enregistrer le like.')),
      );
    }
  }

  void _openLikesReceived() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LikesReceivedScreen()),
    );
  }

  Future<void> _toggleBlock() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    final wasBlocked = _peerBlocked;
    final name = _displayName.isEmpty
        ? AppStrings.t('incoming_someone').toLowerCase()
        : _displayName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t(
            wasBlocked ? 'unblock_peer_q' : 'block_peer_q',
            args: {'name': name},
          ),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t(
              wasBlocked ? 'unblock_peer_body' : 'block_peer_body'),
          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: wasBlocked
                  ? WhatsAppCallTheme.accent
                  : const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.t(wasBlocked ? 'unblock' : 'block')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (wasBlocked) {
        await BlockApi.unblock(blockerId: _deviceId, blockedId: _targetId);
      } else {
        await BlockApi.block(blockerId: _deviceId, blockedId: _targetId);
      }
      if (!mounted) return;
      setState(() => _peerBlocked = !wasBlocked);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  /// Follow the displayed peer back. Reachable only when they already
  /// follow me and I haven't followed them yet (see the button gating in
  /// [_IdentitySection]). Optimistic — roll back if the write fails.
  Future<void> _followBack() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    setState(() => _iFollowPeer = true);
    try {
      await FriendshipApi.sendRequest(meId: _deviceId, peerId: _targetId);
      if (!mounted) return;
      // Re-pull so the followers/following counts reflect the new edge.
      await _reload(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _iFollowPeer = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  /// Unfollow the displayed peer — removes them from my friends. Reachable
  /// only when I already follow them (see the button gating in
  /// [_IdentitySection]). Confirms first, then optimistic with rollback.
  Future<void> _unfollowPeer() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    final name = _displayName.isEmpty
        ? AppStrings.t('incoming_someone').toLowerCase()
        : _displayName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t('unfollow_q', args: {'name': name}),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t('unfollow_body'),
          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.t('follow_unfollow')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _iFollowPeer = false);
    try {
      await FriendshipApi.unfollow(meId: _deviceId, peerId: _targetId);
      if (!mounted) return;
      // Re-pull so the followers/following counts reflect the dropped edge.
      await _reload(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _iFollowPeer = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  Future<void> _openChatWithPeer() async {
    if (_deviceId.isEmpty || _targetId.isEmpty) return;
    final ids = [_deviceId, _targetId]..sort();
    final convId = 'dm-${ids[0]}-${ids[1]}';
    final title = _displayName.isEmpty
        ? AppStrings.t('profile_anonymous')
        : _displayName;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatThreadScreen(
          conversationId: convId,
          title: title,
          peerDeviceId: _targetId,
        ),
      ),
    );
  }

  Future<void> _openFriendsList(FriendDirection direction) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FriendsListScreen(direction: direction),
      ),
    );
    // Counts may have changed (follow-back).
    await _reload();
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_deviceId.isEmpty) return;
    if (!isSupabaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Supabase non configuré.')),
      );
      return;
    }
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final ext = file.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    try {
      await ProfileApi.uploadAvatar(
        deviceId: _deviceId,
        bytes: bytes,
        contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
      );
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload échoué : $e'),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  Future<void> _openEditor() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => OnboardingScreen(
          editing: true,
          onCompleted: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
    await _reload();
  }

  String get _displayName {
    final remote = _remote?.displayName.trim() ?? '';
    if (remote.isNotEmpty) return remote;
    return _local?.firstName.trim() ?? '';
  }

  String get _languageCode {
    final remote = _remote?.language.trim() ?? '';
    if (remote.isNotEmpty) return remote;
    return _local?.sourceLang.trim() ?? '';
  }

  String get _handle {
    final h = _remote?.handle.trim() ?? '';
    if (h.isNotEmpty) return '@$h';
    return '@${_deviceId.replaceAll('-', '').substring(0, 8)}';
  }

  /// True when viewing a peer who is currently online — `last_seen`
  /// within the last 2 minutes — and who has not hidden their status.
  bool get _peerOnline {
    if (!_isViewingOther) return false;
    final r = _remote;
    if (r == null || r.hideOnlineStatus) return false;
    final ls = r.lastSeen;
    if (ls == null) return false;
    return DateTime.now().difference(ls) < const Duration(minutes: 2);
  }

  Future<void> _pickAndUploadDiscoverPhoto() async {
    if (_deviceId.isEmpty) return;
    if (!isSupabaseReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Supabase non configuré.')),
      );
      return;
    }
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      // The Discover card is portrait — keep more pixels than the avatar
      // (1024² → 1600 max edge) so the photo doesn't look soft full-screen.
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final ext = file.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    try {
      await ProfileApi.uploadDiscoverPhoto(
        deviceId: _deviceId,
        bytes: bytes,
        contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
      );
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload échoué : $e'),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  Future<void> _deleteDiscoverPhoto() async {
    if (_deviceId.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WhatsAppCallTheme.bar,
        title: Text(
          AppStrings.t('delete_photo_q'),
          style: const TextStyle(color: WhatsAppCallTheme.strongText),
        ),
        content: Text(
          AppStrings.t('delete_photo_body'),
          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ProfileApi.deleteMyDiscoverPhoto(_deviceId);
      // Cascade: likes received are tied to the (now-deleted) photo, so
      // drop them too — otherwise the ❤ badge keeps showing on an empty
      // cell. Best-effort; a failure here shouldn't block the deletion.
      try {
        await LikeApi.deleteAllLikersOf(_deviceId);
      } catch (e) {
        debugPrint('cascade like delete failed: $e');
      }
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Suppression échouée : $e')),
      );
    }
  }

  Future<void> _saveBio(String bio) async {
    if (_deviceId.isEmpty) return;
    final saved = await ProfileApi.updateMyBio(userId: _deviceId, bio: bio);
    if (saved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sauvegarde échouée.')),
      );
      return;
    }
    if (!mounted || _remote == null) return;
    setState(() {
      _remote = RemoteProfile(
        id: _remote!.id,
        handle: _remote!.handle,
        displayName: _remote!.displayName,
        language: _remote!.language,
        avatarColor: _remote!.avatarColor,
        avatarUrl: _remote!.avatarUrl,
        discoverPhotoUrl: _remote!.discoverPhotoUrl,
        bio: saved,
        isPro: _remote!.isPro,
        creditsSeconds: _remote!.creditsSeconds,
        creditsResetAt: _remote!.creditsResetAt,
        lifetimeCallSeconds: _remote!.lifetimeCallSeconds,
        proExpiresAt: _remote!.proExpiresAt,
      );
    });
  }

  /// Opens the OS share sheet to invite a friend to Swayco. The native
  /// sheet lists every app that can receive text — WhatsApp, Instagram,
  /// SMS, Mail… — so there's no need for per-app buttons.
  Future<void> _shareInvite() async {
    // sharePositionOrigin is required on iPad (anchors the popover) and
    // harmless elsewhere — pass this screen's bounds.
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: AppStrings.t('invite_share_text'),
          subject: AppStrings.t('invite_friend'),
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // User dismissed the sheet or sharing is unavailable — nothing to do.
    }
  }

  Future<void> _reportPeer() async {
    if (!_isViewingOther || _deviceId.isEmpty || _targetId.isEmpty) return;
    final peerName = _displayName.isEmpty
        ? AppStrings.t('incoming_someone')
        : _displayName;
    await showReportDialog(
      context,
      reporterId: _deviceId,
      reportedId: _targetId,
      peerName: peerName,
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    // Profile data may have changed (e.g. account deleted → ignored;
    // sign-out → routed away by the auth listener).
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final lang = findLanguageByCode(_languageCode);
    return Scaffold(
      backgroundColor: WhatsAppCallTheme.scaffold,
      // AppBar only when pushed as a route to view someone else — gives a
      // back button. The "my profile" tab is mounted in IndexedStack, no
      // back navigation, so no AppBar needed.
      appBar: _isViewingOther
          ? AppBar(
              backgroundColor: WhatsAppCallTheme.scaffold,
              foregroundColor: WhatsAppCallTheme.strongText,
              elevation: 0,
              title: Text(
                _displayName.isEmpty
                    ? AppStrings.t('profile_default_title')
                    : _displayName,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
              actions: [
                PopupMenuButton<String>(
                  tooltip: AppStrings.t('tooltip_more'),
                  icon: const Icon(Icons.more_vert),
                  color: WhatsAppCallTheme.bar,
                  onSelected: (v) {
                    if (v == 'report') _reportPeer();
                    if (v == 'block') _toggleBlock();
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem<String>(
                      value: 'report',
                      child: Row(
                        children: [
                          const Icon(Icons.flag_outlined,
                              size: 18, color: Color(0xFFE53935)),
                          const SizedBox(width: 10),
                          Text(
                            AppStrings.t('report'),
                            style: const TextStyle(
                                color: Color(0xFFE53935)),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'block',
                      child: Row(
                        children: [
                          Icon(
                            _peerBlocked ? Icons.lock_open : Icons.block,
                            size: 18,
                            color: const Color(0xFFE53935),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            AppStrings.t(_peerBlocked ? 'unblock' : 'block'),
                            style: const TextStyle(
                                color: Color(0xFFE53935)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: RefreshIndicator(
        color: WhatsAppCallTheme.accent,
        backgroundColor: WhatsAppCallTheme.bar,
        onRefresh: _reload,
        child: _loading
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Column(
                      children: [
                        const CircularProgressIndicator(color: WhatsAppCallTheme.accent),
                        const SizedBox(height: 12),
                        Text(
                          AppStrings.t('profile_loading'),
                          style: const TextStyle(color: WhatsAppCallTheme.subtleText),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                // Reserve room for the floating bottom nav (height 54 + 12 gap)
                // plus the device's bottom safe-area inset, otherwise the last
                // card gets occluded.
                // Horizontal gutter matches the chat / discover headers so
                // the avatar and bio don't run into the screen edge.
                padding: EdgeInsets.fromLTRB(
                  28, 20, 28,
                  32 + 64 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  _IdentitySection(
                    displayName: _displayName.isEmpty
                        ? AppStrings.t('profile_anonymous')
                        : _displayName,
                    handle: _handle,
                    online: _peerOnline,
                    avatarColorHex: _remote?.avatarColor,
                    avatarUrl: _remote?.avatarUrl,
                    bio: _remote?.bio ?? '',
                    counts: _counts,
                    likesCount: _likesCount,
                    discoverPhotoUrl: _remote?.discoverPhotoUrl ?? '',
                    viewerMode: _isViewingOther,
                    peerFollowsMe: _peerFollowsMe,
                    iFollowPeer: _iFollowPeer,
                    iLikePeer: _iLikePeer,
                    onTapAvatar: _pickAndUploadAvatar,
                    onEditBio: _saveBio,
                    onTapFollowers: () => _openFriendsList(FriendDirection.followers),
                    onTapFollowing: () => _openFriendsList(FriendDirection.following),
                    onTapLikes: _openLikesReceived,
                    onPickDiscoverPhoto: _pickAndUploadDiscoverPhoto,
                    onDeleteDiscoverPhoto: _deleteDiscoverPhoto,
                    onEdit: _openEditor,
                    onSettings: _openSettings,
                    onFollowBack: _followBack,
                    onUnfollow: _unfollowPeer,
                    onTogglePeerLike: _togglePeerLike,
                    onMessagePeer: _openChatWithPeer,
                  ),
                  const SizedBox(height: 20),
                  // "Invite a friend to Swayco" — own profile only, sits
                  // between the identity block and the language card.
                  if (!_isViewingOther) ...[
                    _InviteFriendCard(onTap: _shareInvite),
                    const SizedBox(height: 16),
                  ],
                  _LanguageCard(
                    language: lang,
                    showCallWarning: !_isViewingOther,
                  ),
                  if (!_isViewingOther) ...[
                    const SizedBox(height: 16),
                    _CreditsCard(profile: _remote),
                    const SizedBox(height: 16),
                    // Voice-clone card. Shown to ALL tiers when viewing
                    // your own profile — Ultra users get the recording
                    // flow, everyone else gets a locked state that
                    // points at the Ultra checkout. The visible "🔒
                    // Réservé Ultra" hint is a deliberate upsell hook;
                    // hiding the feature for non-Ultra would forfeit
                    // the conversion event.
                    if (!_isViewingOther) ...[
                      _VoiceCloneCard(
                        isUltra: _remote?.isUltra == true,
                        alreadyEnrolled: _remote?.hasClonedVoice == true,
                        onEnrolled: () {
                          // Refresh the remote profile so the badge
                          // flips to "Voix clonée" without a manual
                          // pull-to-refresh.
                          unawaited(_reload(silent: true));
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    _PlansSection(
                      currentTier: _remote?.subscriptionTier ?? 'free',
                    ),
                  ],
                ],
              ),
        ),
          ),
          // When viewing someone else's profile this screen is a route
          // pushed on top of [RootShell], so the shell's floating nav bar
          // is hidden. Re-render it here and route taps back to the shell.
          if (_isViewingOther)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12 + MediaQuery.paddingOf(context).bottom,
              child: Center(
                child: ValueListenableBuilder<int>(
                  valueListenable: NavTab.index,
                  builder: (context, navIndex, _) =>
                      ValueListenableBuilder<int>(
                    valueListenable: ChatUnread.count,
                    builder: (context, unread, _) => GlassNavBar(
                      selected: navIndex,
                      unreadChat: unread,
                      onSelect: (i) {
                        NavTab.select(i);
                        if (i == NavTab.chat) ChatUnread.markAllSeen();
                        // Pop every pushed route so the shell — now on
                        // tab [i] — is visible underneath.
                        Navigator.of(context)
                            .popUntil((route) => route.isFirst);
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact translation-credits indicator. Anxiety-by-stopwatch was the
/// number one piece of OpenAI's UX feedback on this surface, so the
/// card no longer renders the giant "X min remaining" + lifetime grid.
/// Instead it shows:
///   - one line of "X crédits restants" in the active tier's unit,
///   - the tier badge,
///   - an accent-coloured warning if the user has dropped under 20%
///     of their monthly allotment,
///   - the upgrade CTA when not on a paid tier,
///   - the Stripe portal link on web for paid users.
///
/// Ultra subscribers never see a number — only "Illimité", because
/// the fair-use cap (2000 crédits) exists to bound runaway billing,
/// not to be displayed as a quota.
class _CreditsCard extends StatelessWidget {
  const _CreditsCard({required this.profile});

  final RemoteProfile? profile;

  /// Per-tier monthly allotment used to compute the "low credits"
  /// warning threshold (we flash a hint at <20%). Mirrors the
  /// constants exported by profile_api.dart.
  static int _monthlyAllotmentFor(String tier) {
    switch (tier) {
      case 'ultra_plus':
        return ultraPlusMonthlyCreditsSeconds;
      case 'plus':
        return plusMonthlyCreditsSeconds;
      default:
        return freeMonthlyCreditsSeconds;
    }
  }

  static String _formatMinutes(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (m == 0) return '${h}h';
    return '${h}h ${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final tier = p?.subscriptionTier ?? 'free';
    final isTopTier = tier == 'ultra_plus';
    final isPaid = tier != 'free';
    final creditsSeconds = p?.creditsSeconds ?? 0;
    final lifetimeSeconds = p?.lifetimeCallSeconds ?? 0;
    final credits = creditsSeconds ~/ 60;
    final allotment = _monthlyAllotmentFor(tier) ~/ 60;
    // Threshold for the low-credits warning. Hidden entirely for the
    // top tier — it's marketed as "Illimité" so flashing a low-credits
    // hint would contradict the brand promise.
    final lowThreshold = (allotment * 0.2).floor();
    final lowCredits = !isTopTier && allotment > 0 && credits <= lowThreshold;

    final tierLabel = () {
      switch (tier) {
        case 'ultra_plus':
          return 'ULTRA PLUS';
        case 'plus':
          return 'PLUS';
        default:
          return '';
      }
    }();

    return Container(
      decoration: BoxDecoration(
        gradient: isPaid
            ? const LinearGradient(
                colors: [Color(0xFF1F3A34), Color(0xFF0F2A26)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isPaid ? null : WhatsAppCallTheme.bar,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: lowCredits
              ? const Color(0xFFFFA726)
              : (isPaid
                  ? WhatsAppCallTheme.accent.withValues(alpha: 0.45)
                  : const Color(0xFF2A3942)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isTopTier
                      ? AppStrings.t('credits_unlimited')
                      : AppStrings.t(
                          'credits_remaining_inline',
                          args: {'count': credits.toString()},
                        ),
                  style: TextStyle(
                    color: lowCredits
                        ? const Color(0xFFFFA726)
                        : WhatsAppCallTheme.strongText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (tierLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: WhatsAppCallTheme.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    tierLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
            ],
          ),
          if (lowCredits) ...[
            const SizedBox(height: 6),
            Text(
              AppStrings.t('credits_low_hint'),
              style: const TextStyle(
                color: Color(0xFFFFA726),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
          // Discreet lifetime-call-time line under the main row.
          // Kept small + subtle so it stays informative without
          // turning the card back into a stopwatch.
          if (lifetimeSeconds > 0) ...[
            const SizedBox(height: 6),
            Text(
              AppStrings.t(
                'credits_used_total_inline',
                args: {'time': _formatMinutes(lifetimeSeconds)},
              ),
              style: const TextStyle(
                color: WhatsAppCallTheme.subtleText,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ],
          // Paid users on web get the Stripe Customer Portal link
          // (cancel, change card, swap tier). Native users go through
          // App Store / Play Store subscription management instead.
          if (isPaid && kIsWeb) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: const _ManageSubscriptionButton(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Plans section rendered below the credits card on the user's own
/// profile. Two presentations depending on the build target:
///   - Web: in-app pricing cards (Pro 29€ / Ultra 59€) since the web
///     subscription flow is fully ours.
///   - Native (iOS / Android): a single "manage your subscription on
///     our website" card with a copyable URL. Stores enforce in-app
///     purchases for any subscription that unlocks app features, so
///     we deliberately don't surface pricing in the app shell — users
///     bounce to swayco.fr to subscribe.
class _PlansSection extends StatefulWidget {
  const _PlansSection({required this.currentTier});

  /// Caller's current subscription tier. Drives which upgrade cards we
  /// render — only tiers *strictly above* this one show up, so a Plus
  /// subscriber sees Pro + Ultra, a Pro sees Ultra, and an Ultra sees
  /// nothing (we hide the whole section).
  final String currentTier;

  static const String _manageUrl = 'swayco.fr';

  /// Ordered tier ladder. The index of [tier] in this list is used to
  /// decide which cards are "above" the user's current tier — anything
  /// at a strictly greater index is a valid upgrade target.
  static const List<String> _ladder = ['free', 'plus', 'ultra_plus'];

  static int _rank(String tier) {
    final i = _ladder.indexOf(tier);
    return i < 0 ? 0 : i;
  }

  @override
  State<_PlansSection> createState() => _PlansSectionState();
}

class _PlansSectionState extends State<_PlansSection> {
  /// Which tier currently shows the accent (green) border. Initially
  /// the first upgrade above the user's tier so the section opens with
  /// a sensible default highlight.
  String? _selected;

  // Per-tier marketing copy, kept inline so the build below is just a
  // filter over this map — adding a tier later means editing this one
  // place and the ladder in _PlansSection.
  static final Map<String, _PlanCopy> _copy = {
    'plus': _PlanCopy(
      price: '9.97€/mois',
      audience:
          'Pour découvrir, dater, swiper sans limite et écouter la traduction des messages vocaux.',
      features: [
        '300 crédits de traduction',
        'doublage audio des messages vocaux',
        'voir qui t\'a liké',
        'swipes illimités',
        '1 boost / semaine',
      ],
    ),
    'ultra_plus': _PlanCopy(
      price: '19.97€/mois',
      audience:
          'Pour couples internationaux, créateurs, gamers — appels quotidiens.',
      features: [
        'Traduction illimitée',
        'doublage avec TA voix clonée',
        'top placement Discover',
        'voix premium ElevenLabs',
        '5 boosts / semaine',
        'filtres avancés',
      ],
    ),
  };

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      // Native — direct users to the web flow.
      return _ManageOnWebCard(url: _PlansSection._manageUrl);
    }
    // Tiers strictly above the user's current one. Ultra users see no
    // upgrade cards at all → the whole section vanishes.
    final myRank = _PlansSection._rank(widget.currentTier);
    final upgrades = _PlansSection._ladder
        .skip(myRank + 1)
        .where(_copy.containsKey)
        .toList(growable: false);
    if (upgrades.isEmpty) return const SizedBox.shrink();

    // Default the highlighted card to the cheapest available upgrade
    // (= the closest step up). Idempotent: re-runs only update when
    // the selection is missing or no longer in the visible set.
    final defaultSelected = upgrades.first;
    final effectiveSelected =
        (_selected != null && upgrades.contains(_selected!))
            ? _selected!
            : defaultSelected;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final cards = [
          for (var i = 0; i < upgrades.length; i++)
            _PlanCard(
              tier: upgrades[i],
              name: _displayName(upgrades[i]),
              price: _copy[upgrades[i]]!.price,
              audience: _copy[upgrades[i]]!.audience,
              features: _copy[upgrades[i]]!.features,
              featured: effectiveSelected == upgrades[i],
              // "Populaire" sits on the closest upgrade (highest
              // conversion target for the user's current tier).
              popularBadge: i == 0,
              onTap: () => setState(() => _selected = upgrades[i]),
            ),
        ];
        // Wide layout: lay the upgrade tiers side-by-side so the user
        // can compare them at a glance. Below ~720 px the cards would
        // get crushed (the bullet list wraps awkwardly past 5+ items)
        // so we fall back to the vertical stack at narrower widths
        // and on mobile.
        const wideBreakpoint = 720.0;
        if (constraints.maxWidth >= wideBreakpoint && cards.length >= 2) {
          // IntrinsicHeight + crossAxisAlignment.stretch pads every
          // card up to the tallest one so the cards align flush along
          // both edges. Without this the shorter "Plus" card floats
          // above the bottom of the taller "Ultra Plus" card and the
          // row looks lopsided.
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  Expanded(child: cards[i]),
                ],
              ],
            ),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              cards[i],
            ],
          ],
        );
      },
    );
  }

  /// Marketing-style display name for a tier key. Special-cased so the
  /// composite key `ultra_plus` renders as "Ultra Plus" instead of the
  /// generic capitalise-first-letter behaviour.
  static String _displayName(String tier) {
    if (tier == 'ultra_plus') return 'Ultra Plus';
    if (tier.isEmpty) return tier;
    return '${tier[0].toUpperCase()}${tier.substring(1)}';
  }
}

/// Marketing copy for a single tier — small POD so the [build] method
/// can iterate over the visible-upgrades list without giant inline
/// blocks per tier.
class _PlanCopy {
  const _PlanCopy({
    required this.price,
    required this.audience,
    required this.features,
  });
  final String price;
  final String audience;
  final List<String> features;
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.tier,
    required this.name,
    required this.price,
    required this.audience,
    required this.features,
    required this.featured,
    required this.popularBadge,
    this.onTap,
  });

  /// Raw tier key (e.g. `ultra_plus`) — what we send to the backend
  /// when starting checkout. Distinct from the display [name] so we
  /// don't accidentally `name.toLowerCase()` a string like
  /// "Ultra Plus" and end up posting `tier: "ultra plus"` (space).
  final String tier;
  final String name;
  final String price;
  final String audience;
  final List<String> features;

  /// Visually flagged tier — accent-coloured border + accent price /
  /// bullets / CTA to draw the eye toward this option.
  final bool featured;

  /// Render a "Populaire" badge in the top-right corner. Independent
  /// of [featured] in the API so a tier can be visually featured
  /// without claiming popularity (or vice versa).
  final bool popularBadge;

  /// Tap anywhere on the card body to claim the accent border. The
  /// Souscrire button keeps its own onPressed, so taps that land on
  /// the button still go straight to checkout instead of just
  /// re-selecting the card.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = featured
        ? WhatsAppCallTheme.accent
        : const Color(0xFF2A3942);
    // GestureDetector around the whole body so users can claim the
    // accent border by tapping anywhere on the card. The Souscrire
    // FilledButton has its own gesture arena and still wins on its
    // own bounds, so this doesn't steal checkout taps.
    Widget wrap(Widget child) => MouseRegion(
      cursor: onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
    final card = Container(
      decoration: BoxDecoration(
        color: WhatsAppCallTheme.bar,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: featured ? 1.5 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                name,
                style: const TextStyle(
                  color: WhatsAppCallTheme.strongText,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                price,
                style: TextStyle(
                  color: featured
                      ? WhatsAppCallTheme.accent
                      : WhatsAppCallTheme.strongText,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            audience,
            style: const TextStyle(
              color: WhatsAppCallTheme.subtleText,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          for (final f in features)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(
                      Icons.check_circle,
                      size: 16,
                      color: featured
                          ? WhatsAppCallTheme.accent
                          : WhatsAppCallTheme.subtleText,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      f,
                      style: const TextStyle(
                        color: WhatsAppCallTheme.strongText,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Push the Souscrire button to the bottom of the card so two
          // cards laid side-by-side on desktop (IntrinsicHeight Row)
          // align their CTAs along a single baseline regardless of how
          // many feature bullets each tier has.
          const Spacer(),
          const SizedBox(height: 8),
          _SubscribeButton(tier: tier, label: 'Souscrire $name'),
        ],
      ),
    );

    if (!popularBadge) return wrap(card);

    // Overlay a "Populaire" badge in the top-right corner. The card
    // gets a little extra top padding so the title row never collides
    // with the badge ribbon.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        wrap(card),
        Positioned(
          top: -10,
          right: 14,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: WhatsAppCallTheme.accent,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: WhatsAppCallTheme.accent.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Text(
              'Populaire',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Tiny card shown on native builds: tells the user the subscription
/// is managed on the web and provides a one-tap copy of the URL.
/// Avoids embedding pricing in the app, which keeps the build
/// store-compatible (Apple §3.1.1: no in-app pointers to external
/// purchase mechanisms with full pricing).
/// Stateful subscribe button so we can show a spinner while the
/// `/api/stripe/checkout` round-trip is in flight. Once we have the
/// URL we redirect the browser to Stripe Checkout (web-only).
class _SubscribeButton extends StatefulWidget {
  const _SubscribeButton({required this.tier, required this.label});

  final String tier;
  final String label;

  @override
  State<_SubscribeButton> createState() => _SubscribeButtonState();
}

class _SubscribeButtonState extends State<_SubscribeButton> {
  bool _busy = false;

  Future<void> _onTap() async {
    setState(() => _busy = true);
    final url = await StripeApi.startCheckout(widget.tier);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Impossible d'ouvrir la page de paiement. Réessaye dans un instant.",
          ),
        ),
      );
      return;
    }
    // Redirect in the same tab on web (Stripe expects an external
    // page), open the system browser on native (won't normally fire
    // since the plans are web-only, but kept defensive).
    await launchUrl(
      Uri.parse(url),
      webOnlyWindowName: '_self',
      mode: LaunchMode.externalApplication,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: _busy ? null : _onTap,
      style: FilledButton.styleFrom(
        backgroundColor: WhatsAppCallTheme.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(44),
      ),
      child: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(
              widget.label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
    );
  }
}

/// Opens the Stripe Customer Portal. Shown on the credits card when
/// the user is already Pro / Ultra so they can cancel / change card /
/// upgrade / downgrade. Web-only — native builds keep the existing
/// [_ManageOnWebCard] pointer.
class _ManageSubscriptionButton extends StatefulWidget {
  const _ManageSubscriptionButton();

  @override
  State<_ManageSubscriptionButton> createState() =>
      _ManageSubscriptionButtonState();
}

class _ManageSubscriptionButtonState extends State<_ManageSubscriptionButton> {
  bool _busy = false;

  Future<void> _onTap() async {
    setState(() => _busy = true);
    final url = await StripeApi.openPortal();
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Impossible d'ouvrir le portail abonnement."),
        ),
      );
      return;
    }
    await launchUrl(
      Uri.parse(url),
      webOnlyWindowName: '_self',
      mode: LaunchMode.externalApplication,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _busy ? null : _onTap,
      icon: _busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.settings_outlined, size: 18),
      label: const Text('Gérer mon abonnement'),
    );
  }
}

class _ManageOnWebCard extends StatelessWidget {
  const _ManageOnWebCard({required this.url});

  final String url;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Lien copié : $url'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WhatsAppCallTheme.bar,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _copy(context),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2A3942)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Gère ton abonnement sur notre site web :',
                      style: TextStyle(
                        color: WhatsAppCallTheme.strongText,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      url,
                      style: const TextStyle(
                        color: WhatsAppCallTheme.accent,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copier',
                icon: const Icon(
                  Icons.copy_rounded,
                  color: WhatsAppCallTheme.subtleText,
                  size: 20,
                ),
                onPressed: () => _copy(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageCard extends StatelessWidget {
  const _LanguageCard({required this.language, this.showCallWarning = true});
  final AppLanguage? language;
  /// The "during calls you have to speak only X" hint only makes sense on
  /// my own profile — not when peeking at someone else's.
  final bool showCallWarning;

  @override
  Widget build(BuildContext context) {
    final flag = language?.flag ?? '🌐';
    final label = language != null
        ? AppStrings.t('profile_speaks', args: {'lang': language!.label})
        : AppStrings.t('profile_no_language');
    final warning = (showCallWarning && language != null)
        ? AppStrings.t('profile_call_language_warning',
            args: {'lang': language!.label})
        : null;
    return Container(
      decoration: BoxDecoration(
        color: WhatsAppCallTheme.bar,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A3942)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(flag, style: const TextStyle(fontSize: 32)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          if (warning != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.info_outline,
                      size: 14, color: WhatsAppCallTheme.subtleText),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    warning,
                    style: const TextStyle(
                      color: WhatsAppCallTheme.subtleText,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Accent-tinted call-to-action card that opens the OS share sheet to
/// invite a friend to Swayco. Deliberately not a dark "bar" card so it
/// reads as an action, not just another panel.
class _InviteFriendCard extends StatelessWidget {
  const _InviteFriendCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WhatsAppCallTheme.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: WhatsAppCallTheme.accent.withValues(alpha: 0.45),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: WhatsAppCallTheme.accent.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.person_add_alt_1,
                    color: WhatsAppCallTheme.accent, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  AppStrings.t('invite_friend'),
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: WhatsAppCallTheme.subtleText, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

/// Insta-style identity section: avatar with camera badge on the left,
/// followers/following counts inline on the right; below, the display name,
/// handle, bio (tap-to-edit) and a compact Discover photo preview, then a
/// row with Edit and Settings buttons. Replaces the previous bunch of
/// separate stacked cards (header / stats / bio / discover photo / buttons).
class _IdentitySection extends StatelessWidget {
  const _IdentitySection({
    required this.displayName,
    required this.handle,
    this.online = false,
    required this.avatarColorHex,
    required this.avatarUrl,
    required this.bio,
    required this.counts,
    required this.likesCount,
    required this.discoverPhotoUrl,
    required this.onTapAvatar,
    required this.onEditBio,
    required this.onTapFollowers,
    required this.onTapFollowing,
    required this.onTapLikes,
    required this.onPickDiscoverPhoto,
    required this.onDeleteDiscoverPhoto,
    required this.onEdit,
    required this.onSettings,
    this.viewerMode = false,
    this.peerFollowsMe = false,
    this.iFollowPeer = false,
    this.onFollowBack,
    this.onUnfollow,
    this.iLikePeer = false,
    this.onTogglePeerLike,
    this.onMessagePeer,
  });

  final String displayName;
  final String handle;
  /// Viewer-mode only: show a green "online" line under the handle.
  final bool online;
  final String? avatarColorHex;
  final String? avatarUrl;
  final String bio;
  final FriendshipCounts counts;
  /// Number of users who liked me. Only shown on my own profile (private).
  final int likesCount;
  final String discoverPhotoUrl;
  final VoidCallback onTapAvatar;
  final Future<void> Function(String) onEditBio;
  final VoidCallback onTapFollowers;
  final VoidCallback onTapFollowing;
  final VoidCallback onTapLikes;
  final VoidCallback onPickDiscoverPhoto;
  final VoidCallback onDeleteDiscoverPhoto;
  final VoidCallback onEdit;
  final VoidCallback onSettings;
  /// True when this section is rendering someone else's profile read-only.
  /// Hides the camera badge, the bio edit affordance, the discover-photo
  /// upload affordance, and swaps Edit/Paramètres for Message / Follow-back.
  final bool viewerMode;
  /// Viewer-mode only: does the displayed peer follow me? Gates the
  /// "Follow back" button.
  final bool peerFollowsMe;
  /// Viewer-mode only: do I already follow the displayed peer?
  final bool iFollowPeer;
  /// Viewer-mode only: follow the peer back.
  final VoidCallback? onFollowBack;
  /// Viewer-mode only: unfollow the peer (removes them from my friends).
  final VoidCallback? onUnfollow;
  /// Viewer-mode only: have I liked this peer? Drives the heart overlay
  /// on their photo cell.
  final bool iLikePeer;
  final VoidCallback? onTogglePeerLike;
  /// Viewer-mode only: opens the DM thread with this peer.
  final VoidCallback? onMessagePeer;

  // Pulled from AppStrings so it follows the user's chosen interface
  // language (fr / en / es supplied; others fall back to en).
  static String get _bioPlaceholder =>
      AppStrings.t('profile_bio_placeholder');

  Future<void> _openBioEditor(BuildContext context) async {
    final ctrl = TextEditingController(text: bio);
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: WhatsAppCallTheme.bar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20, 16, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppStrings.t('bio_editor_title'),
              style: const TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: profileBioMaxLength,
              maxLines: 3,
              minLines: 2,
              cursorColor: WhatsAppCallTheme.accent,
              style: const TextStyle(color: WhatsAppCallTheme.strongText),
              decoration: InputDecoration(
                hintText: _bioPlaceholder,
                hintStyle: const TextStyle(color: WhatsAppCallTheme.subtleText),
                filled: true,
                fillColor: WhatsAppCallTheme.scaffold,
                border: const OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              style: FilledButton.styleFrom(
                backgroundColor: WhatsAppCallTheme.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(AppStrings.t('save')),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (result != null && result != bio) {
      await onEditBio(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final emptyBio = bio.trim().isEmpty;
    // Posts count for now = 1 if a Discover photo is set, else 0. Wired to
    // a real `posts` table once multi-post support ships (see SQL in commit).
    final postsCount = discoverPhotoUrl.isNotEmpty ? 1 : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Centred avatar (TikTok-style) with the camera badge bottom-right
        // when editing my own profile.
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            ProfileAvatar(
              displayName: displayName,
              avatarUrl: avatarUrl,
              avatarColorHex: avatarColorHex,
              size: 96,
              fontSize: 40,
              onTap: viewerMode ? null : onTapAvatar,
            ),
            if (!viewerMode)
              Container(
                width: 28, height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: WhatsAppCallTheme.accent,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: WhatsAppCallTheme.scaffold, width: 2),
                ),
                child: const Icon(Icons.camera_alt,
                    size: 14, color: Colors.white),
              ),
          ],
        ),
        const SizedBox(height: 14),
        // Centred name + handle.
        Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: WhatsAppCallTheme.strongText,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          handle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: WhatsAppCallTheme.subtleText, fontSize: 13,
          ),
        ),
        // Online indicator — viewer mode, peer active in the last 2 min
        // and not hiding their status.
        if (online) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: WhatsAppCallTheme.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                AppStrings.t('online_now'),
                style: const TextStyle(
                  color: WhatsAppCallTheme.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        // Stats row, TikTok-style. On my own profile we add a private
        // posts | followers | following. Likes count moved to a badge on
        // the Discover photo cell below (private to me, not shown in
        // viewer mode).
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _InlineStat(
              value: postsCount,
              label: 'posts',
            ),
            const _StatDivider(),
            _InlineStat(
              value: counts.followers,
              label: AppStrings.t('profile_followers').toLowerCase(),
              onTap: onTapFollowers,
            ),
            const _StatDivider(),
            _InlineStat(
              value: counts.following,
              label: AppStrings.t('profile_following').toLowerCase(),
              onTap: onTapFollowing,
            ),
          ],
        ),
        // Bio centred, TikTok-style. Tap-to-edit on my own profile, flat
        // text on someone else's (skipped if empty in viewer mode).
        if (!viewerMode) ...[
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openBioEditor(context),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Text(
                emptyBio ? _bioPlaceholder : bio,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: emptyBio
                      ? WhatsAppCallTheme.subtleText
                      : WhatsAppCallTheme.strongText,
                  fontSize: 14,
                  height: 1.4,
                  fontStyle: emptyBio ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
          ),
        ] else if (!emptyBio) ...[
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              bio,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WhatsAppCallTheme.strongText,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Big primary action button — gradient like TikTok's Follow.
        Row(
          children: [
            if (!viewerMode) ...[
              Expanded(
                child: _GradientActionButton(
                  label: AppStrings.t('profile_edit'),
                  icon: Icons.edit_outlined,
                  onTap: onEdit,
                ),
              ),
              const SizedBox(width: 8),
              _GhostIconButton(
                icon: Icons.settings_outlined,
                onTap: onSettings,
                tooltip: AppStrings.t('settings_title'),
              ),
            ] else ...[
              Expanded(
                child: Column(
                  children: [
                    _GradientActionButton(
                      label: AppStrings.t('profile_message'),
                      icon: Icons.chat_bubble_outline,
                      onTap: onMessagePeer ?? () {},
                    ),
                    // Second action depends on the follow relation:
                    //  • peer follows me, I don't follow back → "Follow back"
                    //  • I already follow them → "Unfollow" (removes them
                    //    from my friends)
                    //  • strangers → nothing (Message button on its own)
                    if (peerFollowsMe && !iFollowPeer) ...[
                      const SizedBox(height: 10),
                      _GradientActionButton(
                        label: AppStrings.t('follow_back'),
                        icon: Icons.person_add_alt_1,
                        onTap: onFollowBack ?? () {},
                      ),
                    ] else if (iFollowPeer) ...[
                      const SizedBox(height: 10),
                      _GradientActionButton(
                        label: AppStrings.t('follow_unfollow'),
                        icon: Icons.person_remove_alt_1,
                        onTap: onUnfollow ?? () {},
                        subdued: true,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 22),
        // Instagram-style 3-column grid. Slot 0 is the Discover photo
        // (the only real one for now). Slots 1-2 tease where future
        // photos will live — tappable on my own profile (opens the
        // gallery picker), inert when viewing someone else.
        _PhotosGrid(
          discoverPhotoUrl: discoverPhotoUrl,
          viewerMode: viewerMode,
          onPick: onPickDiscoverPhoto,
          onDelete: onDeleteDiscoverPhoto,
          // Likes badge only on my own profile (private). Tap it → opens
          // the "Qui m'a liké" screen.
          likesCount: viewerMode ? 0 : likesCount,
          onTapLikes: onTapLikes,
          // Viewer mode: heart overlay so I can like the peer's photo.
          iLikePeer: iLikePeer,
          onTogglePeerLike: onTogglePeerLike,
        ),
      ],
    );
  }
}

class _PhotosGrid extends StatelessWidget {
  const _PhotosGrid({
    required this.discoverPhotoUrl,
    required this.viewerMode,
    required this.onPick,
    this.onDelete,
    this.likesCount = 0,
    this.onTapLikes,
    this.iLikePeer = false,
    this.onTogglePeerLike,
  });

  final String discoverPhotoUrl;
  final bool viewerMode;
  final VoidCallback onPick;
  final VoidCallback? onDelete;
  final int likesCount;
  final VoidCallback? onTapLikes;
  final bool iLikePeer;
  final VoidCallback? onTogglePeerLike;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = discoverPhotoUrl.isNotEmpty;
    if (viewerMode && !hasPhoto) return const SizedBox.shrink();
    // Own profile with no photo yet → a full-width call-to-action that
    // explains why a Discover photo matters, instead of a lonely empty
    // grid cell.
    if (!viewerMode && !hasPhoto) {
      return _AddDiscoverPhotoCta(onTap: onPick);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: 1 / 3,
        child: AspectRatio(
          aspectRatio: 1,
          child: _PhotoCell(
            photoUrl: hasPhoto ? discoverPhotoUrl : null,
            viewerMode: viewerMode,
            onTap: onPick,
            onDelete: onDelete,
            likesCount: likesCount,
            onTapLikes: onTapLikes,
            iLikePeer: iLikePeer,
            onTogglePeerLike: onTogglePeerLike,
          ),
        ),
      ),
    );
  }
}

/// Shown on the user's own profile when they have no Discover photo yet
/// — an accent-tinted card nudging them to add one so they appear in the
/// Discover stack.
class _AddDiscoverPhotoCta extends StatelessWidget {
  const _AddDiscoverPhotoCta({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WhatsAppCallTheme.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: WhatsAppCallTheme.accent.withValues(alpha: 0.45),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 16, 16, 16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: WhatsAppCallTheme.accent.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_a_photo_rounded,
                    color: WhatsAppCallTheme.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppStrings.t('discover_photo_cta_title'),
                      style: const TextStyle(
                        color: WhatsAppCallTheme.strongText,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      AppStrings.t('discover_photo_cta_body'),
                      style: const TextStyle(
                        color: WhatsAppCallTheme.subtleText,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoCell extends StatelessWidget {
  const _PhotoCell({
    required this.photoUrl,
    required this.viewerMode,
    required this.onTap,
    this.onDelete,
    this.likesCount = 0,
    this.onTapLikes,
    this.iLikePeer = false,
    this.onTogglePeerLike,
  });

  final String? photoUrl;
  final bool viewerMode;
  final VoidCallback onTap;
  /// When non-null and a photo is set on my own profile, a small trash
  /// button appears top-right to delete the photo.
  final VoidCallback? onDelete;
  final int likesCount;
  final VoidCallback? onTapLikes;
  final bool iLikePeer;
  final VoidCallback? onTogglePeerLike;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    final tappable = !viewerMode;
    // Only render the ❤ badge when there's actually a photo to attach it
    // to (else it floats above an empty "add photo" cell and looks broken)
    // and when there's at least one like to show.
    final showLikesBadge =
        !viewerMode && onTapLikes != null && hasPhoto && likesCount > 0;
    // In viewer mode, render a heart button on the photo so I can like
    // the peer right from their profile. Hidden when there's no photo
    // (the empty cell is already a "image_not_supported" glyph).
    final showLikeAction = viewerMode && hasPhoto && onTogglePeerLike != null;
    // Trash button: only on my own profile when a photo is actually set.
    final showDeleteAction = !viewerMode && hasPhoto && onDelete != null;
    return Material(
      color: WhatsAppCallTheme.bar,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InkWell(
            onTap: tappable ? onTap : null,
            child: hasPhoto
                ? Image.network(
                    photoUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: WhatsAppCallTheme.subtleText),
                    ),
                  )
                : Center(
                    child: Icon(
                      tappable
                          ? Icons.add_a_photo_outlined
                          : Icons.image_not_supported_outlined,
                      color: tappable
                          ? WhatsAppCallTheme.accent
                          : WhatsAppCallTheme.subtleText,
                      size: 22,
                    ),
                  ),
          ),
          if (showLikesBadge)
            Positioned(
              left: 6, bottom: 6,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onTapLikes,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.favorite,
                            size: 12, color: Color(0xFFFF3B5C)),
                        const SizedBox(width: 4),
                        Text(
                          '$likesCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (showDeleteAction)
            Positioned(
              right: 4, top: 4,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onDelete,
                  child: Container(
                    width: 28, height: 28,
                    alignment: Alignment.center,
                    child: const Icon(Icons.delete_outline,
                        color: Color(0xFFFF6B6B), size: 16),
                  ),
                ),
              ),
            ),
          if (showLikeAction)
            Positioned(
              right: 4, bottom: 4,
              child: Material(
                color: iLikePeer
                    ? const Color(0xFFFF3B5C).withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTogglePeerLike,
                  child: Container(
                    width: 30, height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: iLikePeer
                            ? const Color(0xFFFF3B5C)
                            : Colors.white.withValues(alpha: 0.20),
                        width: iLikePeer ? 1.5 : 1,
                      ),
                    ),
                    child: Icon(
                      iLikePeer ? Icons.favorite : Icons.favorite_border,
                      size: iLikePeer ? 16 : 14,
                      color: iLikePeer
                          ? const Color(0xFFFF3B5C)
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InlineStat extends StatelessWidget {
  const _InlineStat({
    required this.value,
    required this.label,
    this.onTap,
  });

  final int value;
  final String label;
  /// Optional — when null the stat is purely decorative (used for the
  /// posts count, which doesn't navigate anywhere yet).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final col = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: WhatsAppCallTheme.strongText,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: WhatsAppCallTheme.subtleText,
            fontSize: 13,
          ),
        ),
      ],
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: col,
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: col,
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1, height: 28,
      color: const Color(0xFF2A3942),
    );
  }
}

class _GradientActionButton extends StatelessWidget {
  const _GradientActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.subdued = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  /// Muted, non-emphasised style — used for the inert "Following" state.
  final bool subdued;

  @override
  Widget build(BuildContext context) {
    // Solid colors instead of gradients — primary accent (site green) for
    // the default action, dark card for the subdued "Following" state.
    final bg = subdued ? WhatsAppCallTheme.bar : WhatsAppCallTheme.accent;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostIconButton extends StatelessWidget {
  const _GhostIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WhatsAppCallTheme.bar,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF2A3942)),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(icon, size: 18,
                color: WhatsAppCallTheme.subtleText),
          ),
        ),
      ),
    );
  }
}

/// Ultra-only "Clone ma voix" card. Lets the user record ~30 s of
/// audio, ships it to /voice/enroll and flips into a green
/// "Voix clonée ✓" state once the backend confirms.
///
/// Tap to start recording → tap again to send → spinner while
/// ElevenLabs processes → state updates. Re-enrolment is supported
/// (record again to overwrite the stored voice_id; backend deletes the
/// previous one to free the slot).
class _VoiceCloneCard extends StatefulWidget {
  const _VoiceCloneCard({
    required this.isUltra,
    required this.alreadyEnrolled,
    required this.onEnrolled,
  });
  /// When false, the card renders a locked state with a "Passer Ultra"
  /// CTA instead of the recording controls — non-Ultra tiers still
  /// see the feature exists so it acts as an upsell.
  final bool isUltra;
  final bool alreadyEnrolled;
  final VoidCallback onEnrolled;

  @override
  State<_VoiceCloneCard> createState() => _VoiceCloneCardState();
}

class _VoiceCloneCardState extends State<_VoiceCloneCard> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _uploading = false;
  DateTime? _recordStart;
  Timer? _tick;
  Duration _elapsed = Duration.zero;
  /// Local override of [widget.alreadyEnrolled] for the moment between
  /// a successful enrol and the parent's profile refetch landing.
  bool _justEnrolled = false;

  /// Recommended sample length for ElevenLabs IVC. Below 20 s the
  /// clone quality drops sharply; above 60 s we hit the cap of the
  /// per-recording quota and stop automatically.
  static const Duration _maxSample = Duration(seconds: 60);
  static const Duration _minSample = Duration(seconds: 20);

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(() async {
      try {
        if (await _recorder.isRecording()) await _recorder.cancel();
      } catch (_) {}
      await _recorder.dispose();
    }());
    super.dispose();
  }

  Future<String> _recordingPath() async {
    if (kIsWeb) return '';
    final dir = await getTemporaryDirectory();
    return '${dir.path}/voice_clone_${DateTime.now().millisecondsSinceEpoch}.m4a';
  }

  Future<void> _start() async {
    if (_recording || _uploading) return;
    try {
      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('voice_mic_denied'))),
        );
        return;
      }
      final path = await _recordingPath();
      // Higher bitrate than chat messages: IVC quality is sensitive to
      // compression artefacts. AAC 96 kbit/s mono 22 kHz is a good
      // compromise that ElevenLabs handles cleanly.
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 22050,
          numChannels: 1,
        ),
        path: path,
      );
      _recordStart = DateTime.now();
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || _recordStart == null) return;
        final el = DateTime.now().difference(_recordStart!);
        if (el >= _maxSample) {
          unawaited(_stopAndUpload());
          return;
        }
        setState(() => _elapsed = el);
      });
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur micro: $e')),
      );
    }
  }

  Future<void> _cancel() async {
    if (!_recording) return;
    _tick?.cancel();
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _recording = false;
        _elapsed = Duration.zero;
        _recordStart = null;
      });
    }
  }

  Future<void> _stopAndUpload() async {
    if (!_recording) return;
    _tick?.cancel();
    final ms = _elapsed.inMilliseconds;
    String? out;
    try {
      out = await _recorder.stop();
    } catch (_) {
      out = null;
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _elapsed = Duration.zero;
      _recordStart = null;
    });
    if (out == null) return;
    if (ms < _minSample.inMilliseconds) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('voice_clone_too_short'))),
      );
      return;
    }
    Uint8List bytes;
    try {
      if (kIsWeb) {
        final res = await http.get(Uri.parse(out));
        bytes = res.bodyBytes;
      } else {
        bytes = await File(out).readAsBytes();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lecture audio échouée: $e')),
        );
      }
      return;
    }
    if (bytes.isEmpty) return;
    setState(() => _uploading = true);
    try {
      await enrollClonedVoice(
        audioBytes: bytes,
        mimeType: kIsWeb ? 'audio/webm' : 'audio/m4a',
      );
      if (!mounted) return;
      setState(() => _justEnrolled = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('voice_clone_success'))),
      );
      widget.onEnrolled();
    } on VoiceEnrollException catch (e) {
      if (!mounted) return;
      final msg = e.code == VoiceEnrollError.upgradeRequired
          ? AppStrings.t('voice_clone_ultra_only')
          : AppStrings.t('voice_clone_failed');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('voice_clone_failed'))),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _openUltraCheckout() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final url = await StripeApi.startCheckout('ultra_plus');
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t('voice_clone_failed'))),
        );
        return;
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('voice_clone_failed'))),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = !widget.isUltra;
    final enrolled = widget.alreadyEnrolled || _justEnrolled;
    final secs = _elapsed.inSeconds;
    final m = (secs ~/ 60).toString().padLeft(1, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: WhatsAppCallTheme.bar,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enrolled
              ? WhatsAppCallTheme.accent
              : const Color(0xFF2A3942),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                locked
                    ? Icons.lock_outline
                    : (enrolled ? Icons.check_circle : Icons.mic_none),
                color: locked
                    ? WhatsAppCallTheme.subtleText
                    : (enrolled
                        ? WhatsAppCallTheme.accent
                        : WhatsAppCallTheme.strongText),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  enrolled
                      ? AppStrings.t('voice_clone_enrolled_title')
                      : AppStrings.t('voice_clone_title'),
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (locked)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: WhatsAppCallTheme.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    AppStrings.t('voice_clone_ultra_badge'),
                    style: const TextStyle(
                      color: WhatsAppCallTheme.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            enrolled
                ? AppStrings.t('voice_clone_enrolled_subtitle')
                : AppStrings.t('voice_clone_subtitle'),
            style: const TextStyle(
              color: WhatsAppCallTheme.subtleText,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          if (locked)
            // Locked state: skip the recording flow entirely and offer
            // a single CTA that drops the user into the Ultra checkout.
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _uploading ? null : _openUltraCheckout,
                icon: _uploading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.bolt, size: 18),
                label: Text(AppStrings.t('voice_clone_unlock')),
              ),
            )
          else if (_recording)
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE53935),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$m:$s',
                  style: const TextStyle(
                    color: WhatsAppCallTheme.strongText,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _cancel,
                  child: Text(AppStrings.t('cancel')),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _stopAndUpload,
                  child: Text(AppStrings.t('voice_clone_send')),
                ),
              ],
            )
          else if (_uploading)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: WhatsAppCallTheme.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  AppStrings.t('voice_clone_processing'),
                  style: const TextStyle(
                    color: WhatsAppCallTheme.subtleText,
                    fontSize: 13,
                  ),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.mic, size: 18),
                label: Text(
                  enrolled
                      ? AppStrings.t('voice_clone_redo')
                      : AppStrings.t('voice_clone_start'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
