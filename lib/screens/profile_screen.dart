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
import 'package:url_launcher/url_launcher.dart';

import '../services/voice_message_api.dart';

import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/chat_unread.dart';
import '../services/friend_request_unread.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/interests.dart';
import '../services/languages.dart';
import '../services/like_api.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/stripe_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
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

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver {
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
  // Viewer-mode only: I sent the peer a friend request that's still
  // pending (they haven't accepted yet). Drives the "Demande envoyée"
  // state on the "Ajouter" button.
  bool _iRequestedPeer = false;
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
    final remote = isSupabaseReady
        ? await ProfileApi.fetchById(targetId)
        : null;
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
    var iRequestedPeer = false;
    if (_isViewingOther && isSupabaseReady && deviceId.isNotEmpty) {
      final rel = await FriendshipApi.directionalWith(
        meId: deviceId,
        peerId: targetId,
      );
      peerFollowsMe = rel.peerFollowsMe;
      iFollowPeer = rel.iFollowPeer;
      iRequestedPeer = rel.iRequestedPeer;
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
      _iRequestedPeer = iRequestedPeer;
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
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t(
        wasBlocked ? 'unblock_peer_q' : 'block_peer_q',
        args: {'name': name},
      ),
      body: AppStrings.t(wasBlocked ? 'unblock_peer_body' : 'block_peer_body'),
      confirmLabel: AppStrings.t(wasBlocked ? 'unblock' : 'block'),
      destructive: !wasBlocked,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  /// "S'abonner en retour": the peer already follows me, so following
  /// them back is an instant abonnement — no approval step (see
  /// [FriendshipApi.follow]). Optimistic — roll back if the write fails.
  Future<void> _followBack() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    setState(() => _iFollowPeer = true);
    try {
      await FriendshipApi.follow(meId: _deviceId, peerId: _targetId);
      if (!mounted) return;
      // Re-pull so the followers/following counts reflect the new edge.
      await _reload(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _iFollowPeer = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  /// "Ajouter": the peer is a stranger (doesn't follow me, I don't
  /// follow them). Unlike follow-back this SENDS A REQUEST that they
  /// must accept — lands as `pending`. Optimistic: flip the button to
  /// "Demande envoyée"; roll back if the write fails.
  Future<void> _addPeer() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    setState(() => _iRequestedPeer = true);
    try {
      await FriendshipApi.sendRequest(meId: _deviceId, peerId: _targetId);
      if (!mounted) return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _iRequestedPeer = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
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
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('unfollow_q', args: {'name': name}),
      body: AppStrings.t('unfollow_body'),
      confirmLabel: AppStrings.t('follow_unfollow'),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
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
    // On someone else's profile, tap their follower / following count
    // → show THEIR list, not mine. _targetId resolves to the peer's
    // id in viewer mode and falls back to the local device id on the
    // user's own profile.
    final targetId = _isViewingOther ? widget.userId : null;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            FriendsListScreen(direction: direction, userId: targetId),
      ),
    );
    // Counts may have changed (follow-back).
    await _reload();
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

  /// "Tes photos" — pick an image and append it to the gallery. The first
  /// photo doubles as the PDP (avatar) + Discover photo; [ProfileApi.
  /// addProfilePhoto] keeps those columns in sync.
  Future<void> _pickAndAddPhoto() async {
    if (_deviceId.isEmpty) return;
    if (!isSupabaseReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Supabase non configuré.')));
      return;
    }
    final current = _remote?.photos ?? const <String>[];
    if (current.length >= profilePhotosMax) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('photos_full'))));
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
      await ProfileApi.addProfilePhoto(
        deviceId: _deviceId,
        bytes: bytes,
        current: current,
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

  /// PDP bubble — pick an image and set it as the (independent) profile
  /// avatar via [ProfileApi.uploadAvatar]. Separate from the gallery: this
  /// only writes `avatar_url`, leaving "Tes photos" untouched.
  Future<void> _pickAndSetAvatar() async {
    if (_deviceId.isEmpty) return;
    if (!isSupabaseReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Supabase non configuré.')));
      return;
    }
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      // The avatar renders small and round — 1024² is plenty and keeps the
      // upload light.
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 88,
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

  /// Remove a single gallery photo. Re-syncs the Discover photo server-side;
  /// cascades a like wipe only when the gallery becomes empty (see
  /// [ProfileApi.removeProfilePhoto]).
  Future<void> _removePhoto(String url) async {
    if (_deviceId.isEmpty) return;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('delete_photo_q'),
      body: AppStrings.t('delete_photo_body'),
      confirmLabel: AppStrings.t('delete'),
    );
    if (ok != true) return;
    try {
      await ProfileApi.removeProfilePhoto(
        deviceId: _deviceId,
        url: url,
        current: _remote?.photos ?? const <String>[],
      );
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Suppression échouée : $e')));
    }
  }

  Future<void> _saveName(String name) async {
    if (_deviceId.isEmpty) return;
    final trimmed = name.trim();
    // Ignore an empty name — a profile must keep one.
    if (trimmed.isEmpty) return;
    final saved =
        await ProfileApi.updateMyName(userId: _deviceId, name: trimmed);
    if (saved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sauvegarde échouée.')));
      return;
    }
    if (!mounted || _remote == null) return;
    setState(() => _remote = _remote!.copyWith(displayName: saved));
  }

  Future<void> _saveBio(String bio) async {
    if (_deviceId.isEmpty) return;
    final saved = await ProfileApi.updateMyBio(userId: _deviceId, bio: bio);
    if (saved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sauvegarde échouée.')));
      return;
    }
    if (!mounted || _remote == null) return;
    setState(() => _remote = _remote!.copyWith(bio: saved));
  }

  Future<void> _saveInterests(List<String> interests) async {
    if (_deviceId.isEmpty) return;
    final saved = await ProfileApi.updateMyInterests(
      userId: _deviceId,
      interests: interests,
    );
    if (saved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sauvegarde échouée.')));
      return;
    }
    if (!mounted || _remote == null) return;
    setState(() => _remote = _remote!.copyWith(interests: saved));
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
      backgroundColor: const Color(0xFF0E0E0E),
      // AppBar only when pushed as a route to view someone else — gives a
      // back button. The "my profile" tab is mounted in IndexedStack, no
      // back navigation, so no AppBar needed.
      extendBodyBehindAppBar: true,
      appBar: _isViewingOther
          ? AppBar(
              backgroundColor: Colors.transparent,
              foregroundColor: SC.textPrimary,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              title: Text(
                _displayName.isEmpty
                    ? AppStrings.t('profile_default_title')
                    : _displayName,
                style: SCText.h3,
              ),
              actions: [
                  PopupMenuButton<String>(
                    tooltip: AppStrings.t('tooltip_more'),
                    icon: const Icon(Icons.more_vert),
                    color: SC.bubbleIn,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: SC.glassBorder),
                    ),
                    onSelected: (v) {
                      if (v == 'report') _reportPeer();
                      if (v == 'block') _toggleBlock();
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem<String>(
                        value: 'report',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.flag_outlined,
                              size: 18,
                              color: Color(0xFFE53935),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              AppStrings.t('report'),
                              style: const TextStyle(color: Color(0xFFE53935)),
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
                              style: const TextStyle(color: Color(0xFFE53935)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            )
          : null,
      body: ColoredBox(
        color: const Color(0xFF0E0E0E),
        child: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: RefreshIndicator(
                color: SC.accent,
                backgroundColor: SC.bubbleIn,
                onRefresh: _reload,
                child: _loading
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 120),
                          Center(
                            child: Column(
                              children: [
                                const CircularProgressIndicator(
                                  color: SC.accent,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  AppStrings.t('profile_loading'),
                                  style: const TextStyle(color: SC.textMuted),
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
                          28,
                          // Own profile: title sits at the very top like the
                          // other tabs (Discover / Messages). Viewer: leave
                          // room for the transparent AppBar drawn behind it.
                          _isViewingOther ? 56 : 12,
                          28,
                          32 + 64 + MediaQuery.paddingOf(context).bottom,
                        ),
                        children: [
                          _IdentitySection(
                            // Raw name (may be empty) — the section shows the
                            // "anonymous" fallback itself in viewer mode and
                            // an editable field on my own profile.
                            displayName: _displayName,
                            handle: _handle,
                            online: _peerOnline,
                            bio: _remote?.bio ?? '',
                            interests: _remote?.interests ?? const [],
                            photos: _remote?.photos ?? const [],
                            avatarUrl: _remote?.avatarUrl ?? '',
                            counts: _counts,
                            likesCount: _likesCount,
                            viewerMode: _isViewingOther,
                            peerFollowsMe: _peerFollowsMe,
                            iFollowPeer: _iFollowPeer,
                            iRequestedPeer: _iRequestedPeer,
                            iLikePeer: _iLikePeer,
                            onEditName: _saveName,
                            onEditBio: _saveBio,
                            onEditInterests: _saveInterests,
                            onTapFollowers: () =>
                                _openFriendsList(FriendDirection.followers),
                            onTapFollowing: () =>
                                _openFriendsList(FriendDirection.following),
                            onTapLikes: _openLikesReceived,
                            onPickPhoto: _pickAndAddPhoto,
                            onPickAvatar: _pickAndSetAvatar,
                            onRemovePhoto: _removePhoto,
                            onEdit: _openEditor,
                            onSettings: _openSettings,
                            onFollowBack: _followBack,
                            onAddPeer: _addPeer,
                            onUnfollow: _unfollowPeer,
                            onTogglePeerLike: _togglePeerLike,
                            onMessagePeer: _openChatWithPeer,
                          ),
                          const SizedBox(height: 20),
                          _LanguageCard(
                            language: lang,
                            showCallWarning: !_isViewingOther,
                          ),
                          if (!_isViewingOther) ...[
                            const SizedBox(height: 16),
                            // Voice-clone card. Shown to ALL tiers when viewing
                            // your own profile — Ultra users get the recording
                            // flow, everyone else gets a locked state that
                            // points at the Ultra checkout. The visible "🔒
                            // Réservé Ultra" hint is a deliberate upsell hook;
                            // hiding the feature for non-Ultra would forfeit
                            // the conversion event.
                            // TEMPORARILY HIDDEN — "Clone my voice" card removed from
                            // the UI on request. The widget and all supporting code
                            // (_VoiceCloneCard, enrollClonedVoice, etc.) are left
                            // intact so this block can simply be uncommented to
                            // restore the feature.
                            // if (!_isViewingOther) ...[
                            //   _VoiceCloneCard(
                            //     isUltra: _remote?.isUltra == true,
                            //     alreadyEnrolled: _remote?.hasClonedVoice == true,
                            //     onEnrolled: () {
                            //       // Refresh the remote profile so the badge
                            //       // flips to "Voix clonée" without a manual
                            //       // pull-to-refresh.
                            //       unawaited(_reload(silent: true));
                            //     },
                            //   ),
                            //   const SizedBox(height: 16),
                            // ],
                            _MySubscriptionSection(
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
                bottom: 0,
                child: ValueListenableBuilder<int>(
                  valueListenable: NavTab.index,
                  builder: (context, navIndex, _) => ValueListenableBuilder<int>(
                    valueListenable: ChatUnread.count,
                    builder: (context, unread, _) =>
                        ValueListenableBuilder<int>(
                          valueListenable: FriendRequestUnread.count,
                          builder: (context, pending, _) => GlassNavBar(
                            selected: navIndex,
                            unreadChat: unread,
                            unreadRequests: pending,
                            onSelect: (i) {
                              NavTab.select(i);
                              if (i == NavTab.chat) ChatUnread.markAllSeen();
                              // Pop every pushed route so the shell — now on
                              // tab [i] — is visible underneath.
                              Navigator.of(
                                context,
                              ).popUntil((route) => route.isFirst);
                            },
                          ),
                        ),
                  ),
                ),
              ),
          ],
        ),
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
/// Translation-credits card ("X credits left this month" + lifetime total).
/// Lives here but is rendered on the Settings screen now (moved off the
/// profile), so it's public.
class CreditsCard extends StatelessWidget {
  const CreditsCard({super.key, required this.profile});

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
        return freeWeeklyCreditsSeconds;
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
    // Still loading: render a neutral skeleton instead of computing the card
    // from a null profile — which would read as 0 credits on the free tier
    // and briefly FLASH the orange "low credits" warning before the real
    // value lands. A muted placeholder bar avoids that flicker.
    if (p == null) {
      return Container(
        decoration: BoxDecoration(
          color: SC.glassStrong,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: SC.glassBorder),
        ),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 150,
            height: 14,
            decoration: BoxDecoration(
              color: SC.textMuted.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
      );
    }
    final tier = p.subscriptionTier;
    final isTopTier = tier == 'ultra_plus';
    final isPaid = tier != 'free';
    final creditsSeconds = p.creditsSeconds;
    final lifetimeSeconds = p.lifetimeCallSeconds;
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
        color: isPaid ? null : SC.glassStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: lowCredits
              ? const Color(0xFFFFA726)
              : (isPaid ? SC.accent.withValues(alpha: 0.45) : SC.glassBorder),
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
                        : SC.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (tierLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: SC.accent,
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
                color: SC.textMuted,
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

/// Collapsible "Mon abonnement" card that gates the upgrade pricing
/// cards behind a header tap. Mirrors the rest of the profile card
/// stack (SC.bubbleIn surface, 16 px radius, slate border) and slides
/// the [_PlansSection] in / out via an AnimatedSize. Hidden entirely
/// when the user is on the top tier (Ultra Plus) — no upgrades to
/// surface.
class _MySubscriptionSection extends StatefulWidget {
  const _MySubscriptionSection({required this.currentTier});

  final String currentTier;

  @override
  State<_MySubscriptionSection> createState() => _MySubscriptionSectionState();
}

class _MySubscriptionSectionState extends State<_MySubscriptionSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // Same gate as _PlansSection: Ultra users see no upgrades, so the
    // whole "Mon abonnement" affordance collapses to nothing.
    final myRank = _PlansSection._rank(widget.currentTier);
    final hasUpgrades = _PlansSection._ladder.skip(myRank + 1).isNotEmpty;
    if (!hasUpgrades) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: SC.glassStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SC.glassBorder),
      ),
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.workspace_premium_outlined,
                      color: SC.accent,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        AppStrings.t('my_subscription_section'),
                        style: const TextStyle(
                          color: SC.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 180),
                      turns: _expanded ? 0.5 : 0.0,
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: SC.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      child: _PlansSection(currentTier: widget.currentTier),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
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
      price: '7,97€/mois',
      audience:
          'Pour écouter la traduction des messages vocaux et débloquer plus de traductions live.',
      features: [
        '180 crédits de traduction (≈ 3 h / mois)',
        'doublage audio des messages vocaux',
      ],
    ),
    'ultra_plus': _PlanCopy(
      price: '15,97€/mois',
      audience:
          'Pour couples internationaux, créateurs, gamers — appels quotidiens.',
      features: [
        '360 crédits de traduction (≈ 6 h / mois)',
        'doublage avec TA voix clonée',
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

    // Default the highlighted card to the *top* upgrade in the visible
    // set — i.e. Ultra Plus for a Free or Plus user. Anchoring the
    // accent on the most premium option nudges conversion upward; the
    // user can still tap Plus to claim the border. Falls back to the
    // first upgrade if for some reason the top one isn't in the list.
    final defaultSelected = upgrades.last;
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
    final borderColor = featured ? SC.accent : const Color(0xFF2A3942);
    // GestureDetector around the whole body so users can claim the
    // accent border by tapping anywhere on the card. The Souscrire
    // FilledButton has its own gesture arena and still wins on its
    // own bounds, so this doesn't steal checkout taps.
    Widget wrap(Widget child) => MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
    final card = Container(
      decoration: BoxDecoration(
        color: SC.glassStrong,
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
                  color: SC.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                price,
                style: TextStyle(
                  color: featured ? SC.accent : SC.textPrimary,
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
              color: SC.textMuted,
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
                      color: featured ? SC.accent : SC.textMuted,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      f,
                      style: const TextStyle(
                        color: SC.textPrimary,
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
          top: -12,
          right: 14,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              // Warm amber pops against the cyan / navy palette of the
              // card body, so the badge reads at a glance instead of
              // blending into the price column above the divider.
              color: const Color(0xFFFFC247),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.45),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFC247).withValues(alpha: 0.55),
                  blurRadius: 14,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Text(
              'Populaire',
              style: TextStyle(
                color: Color(0xFF1A1300),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
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
        // Softer than SC.accent — the brighter cyan was too loud once
        // both pricing cards stacked vertically. accentDeep keeps the
        // Swayco identity while letting the badge / price text breathe.
        backgroundColor: SC.accentDeep,
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
      color: SC.glassStrong,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _copy(context),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SC.glassBorder),
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
                        color: SC.textPrimary,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      url,
                      style: const TextStyle(
                        color: SC.accent,
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
                  color: SC.textMuted,
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
    // Language name localised to the UI language (e.g. "French" in EN,
    // "Français" in FR) — not the native label, so it never reads
    // "Speaks Français".
    final langName =
        language != null ? AppStrings.t('lang_name_${language!.code}') : '';
    final label = language != null
        ? AppStrings.t('profile_speaks', args: {'lang': langName})
        : AppStrings.t('profile_no_language');
    final warning = (showCallWarning && language != null)
        ? AppStrings.t(
            'profile_call_language_warning',
            args: {'lang': langName},
          )
        : null;
    return Container(
      decoration: BoxDecoration(
        color: SC.glassStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SC.glassBorder),
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
                    color: SC.textPrimary,
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
                  child: Icon(
                    Icons.info_outline,
                    size: 14,
                    color: SC.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    warning,
                    style: const TextStyle(
                      color: SC.textMuted,
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
    required this.bio,
    required this.interests,
    required this.photos,
    required this.avatarUrl,
    required this.counts,
    required this.likesCount,
    required this.onEditName,
    required this.onEditBio,
    this.onPickAvatar,
    this.onEditInterests,
    required this.onTapFollowers,
    required this.onTapFollowing,
    required this.onTapLikes,
    required this.onPickPhoto,
    required this.onRemovePhoto,
    required this.onEdit,
    required this.onSettings,
    this.viewerMode = false,
    this.peerFollowsMe = false,
    this.iFollowPeer = false,
    this.iRequestedPeer = false,
    this.onFollowBack,
    this.onAddPeer,
    this.onUnfollow,
    this.iLikePeer = false,
    this.onTogglePeerLike,
    this.onMessagePeer,
  });

  final String displayName;
  final String handle;

  /// Viewer-mode only: show a green "online" line under the handle.
  final bool online;
  final String bio;

  /// "Centres d'intérêt" the user picked (predefined tags). Rendered as
  /// colour-coded chips; editable on my own profile (opens the picker),
  /// read-only otherwise.
  final List<String> interests;

  /// Photo gallery ("Tes photos"). Drives the Discover card via `photos[0]`.
  /// Editable (add / remove) on my own profile, read-only otherwise.
  final List<String> photos;

  /// The profile picture (PDP) shown in the round bubble — an independent
  /// image, no longer tied to `photos[0]`. Empty falls back to initials.
  final String avatarUrl;
  final FriendshipCounts counts;

  /// Number of users who liked me. Only shown on my own profile (private).
  final int likesCount;

  /// Persist the edited display name (own profile, inline).
  final Future<void> Function(String) onEditName;
  final Future<void> Function(String) onEditBio;

  /// Persist the edited interests list. Null in viewer mode (read-only).
  final Future<void> Function(List<String>)? onEditInterests;
  final VoidCallback onTapFollowers;
  final VoidCallback onTapFollowing;
  final VoidCallback onTapLikes;

  /// Own profile: append a photo to the gallery.
  final VoidCallback onPickPhoto;

  /// Own profile: pick + set the independent PDP (avatar). Null in viewer.
  final VoidCallback? onPickAvatar;

  /// Own profile: remove the given gallery photo by URL.
  final void Function(String url) onRemovePhoto;

  /// Own profile: open the editor (name / language) — the header pencil.
  final VoidCallback onEdit;
  final VoidCallback onSettings;

  /// True when this section is rendering someone else's profile read-only.
  /// Hides editing affordances and swaps Edit/Paramètres for Message /
  /// Follow-back.
  final bool viewerMode;

  /// Viewer-mode only: does the displayed peer follow me? Gates the
  /// "Follow back" button.
  final bool peerFollowsMe;

  /// Viewer-mode only: do I already follow the displayed peer?
  final bool iFollowPeer;

  /// Viewer-mode only: I sent a still-pending request via "Ajouter".
  final bool iRequestedPeer;

  /// Viewer-mode only: follow the peer back (instant abonnement).
  final VoidCallback? onFollowBack;

  /// Viewer-mode only: send a friend request to a stranger ("Ajouter").
  final VoidCallback? onAddPeer;

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
  static String get _bioPlaceholder => AppStrings.t('profile_bio_placeholder');

  /// Opens the "Centres d'intérêt" picker (a styled bottom sheet of coloured
  /// category groups) and persists the new selection.
  @override
  Widget build(BuildContext context) {
    return viewerMode ? _buildViewer(context) : _buildOwn(context);
  }

  /// The round PDP bubble — the independent profile picture ([avatarUrl])
  /// shown as a circular avatar at the top of both layouts. On my own
  /// profile it carries the camera badge and a tap sets a new PDP (separate
  /// from the gallery); read-only (no badge / tap) in the viewer.
  Widget _pdpBubble({required bool editable}) {
    final pdp = avatarUrl.isEmpty ? null : avatarUrl;
    return Center(
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          ProfileAvatar(
            displayName: displayName,
            avatarUrl: pdp,
            size: 128,
            fontSize: 54,
            onTap: editable ? onPickAvatar : null,
          ),
          if (editable)
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: SC.accent,
                shape: BoxShape.circle,
                border: Border.all(color: SC.bg, width: 2),
              ),
              child: const Icon(
                Icons.camera_alt,
                size: 14,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  /// My own profile — capture-1 layout: a "Ton profil" header with an edit
  /// pencil, the round PDP bubble, name + @handle, the bio, the stats row
  /// (with the settings gear), then the "Tes photos" gallery and the
  /// "Emojis" section. Everything is editable in place; the pencil opens the
  /// name / language editor.
  Widget _buildOwn(BuildContext context) {
    final photosTitle = photos.isEmpty
        ? AppStrings.t('profile_photos_section')
        : '${AppStrings.t('profile_photos_section')} (${photos.length})';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header — just the "Ton profil" title.
        Text(
          AppStrings.t('onb_profile_title'),
          style: SCText.h1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 26),
        // Round PDP bubble (the independent avatar) — tap to set a new PDP.
        _pdpBubble(editable: true),
        const SizedBox(height: 14),
        // Name centred under the PDP, with a cyan edit bubble towards the
        // right (pulled in 20px from the edge). The left spacer (64 = bubble
        // 44 + margin 20) keeps the name centred.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(width: 68),
            Expanded(
              child: _InlineEditable(
                value: displayName,
                placeholder: AppStrings.t('profile_anonymous'),
                onSave: onEditName,
                maxLength: profileNameMaxLength,
                style: const TextStyle(
                  color: SC.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Material(
              color: SC.accent.withValues(alpha: 0.15),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onEdit,
                child: Tooltip(
                  message: AppStrings.t('profile_edit'),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: SC.accent.withValues(alpha: 0.6)),
                    ),
                    child: const Icon(Icons.edit_outlined,
                        size: 16, color: SC.accent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 32),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          handle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(color: SC.textMuted, fontSize: 13),
        ),
        // Bio — between the name block and the stats. Edited IN PLACE (tap
        // the text → it turns into a field), no bottom-sheet popup. Shows
        // the placeholder when empty so it stays an obvious edit affordance.
        const SizedBox(height: 12),
        _InlineEditable(
          value: bio,
          placeholder: _bioPlaceholder,
          onSave: onEditBio,
          maxLength: profileBioMaxLength,
          maxLines: 2,
          style: const TextStyle(
            color: SC.textPrimary,
            fontSize: 16.5,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        // Stats — posts | followers | following — kept centred on the full
        // width by balancing the right-side gear (38 + 8 gap) with an equal
        // invisible spacer on the left. The gear sits at the stats level.
        Row(
          children: [
            const SizedBox(width: 46),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _InlineStat(value: photos.length, label: 'posts'),
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
            ),
            const SizedBox(width: 8),
            _GhostIconButton(
              icon: Icons.settings_outlined,
              onTap: onSettings,
              tooltip: AppStrings.t('settings_title'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        // "Tes photos (n)" + horizontal gallery (add tile first, then photos).
        _ProfileSectionHeader(photosTitle),
        const SizedBox(height: 12),
        _PhotoGallery(
          photos: photos,
          viewerMode: false,
          onPick: onPickPhoto,
          onRemove: onRemovePhoto,
          likesCount: likesCount,
          onTapLikes: onTapLikes,
        ),
        const SizedBox(height: 10),
        // ⓘ hint — taps jump to Settings where "Me cacher de mon pays" lives.
        _DiscoverVisibilityHint(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
        // Centres d'intérêt — picked chips + an "add" chip; tapping either
        // unfolds the category picker inline, right under the chips (no
        // overlay), then folds back when you're done.
        const SizedBox(height: 24),
        _InterestsSection(
          interests: interests,
          onSave: onEditInterests,
        ),
      ],
    );
  }

  /// Someone else's profile (read-only). Photo gallery + name/handle +
  /// stats + the Message / Follow-back / Add action stack, then the peer's
  /// emojis and bio when present.
  Widget _buildViewer(BuildContext context) {
    final emptyBio = bio.trim().isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Round PDP bubble (the first photo as a circular avatar) at the top —
        // shows the user's initials when they have no photo yet.
        _pdpBubble(editable: false),
        const SizedBox(height: 16),
        // Centred name + handle. Falls back to the anonymous label when the
        // peer has no display name set.
        Text(
          displayName.trim().isEmpty
              ? AppStrings.t('profile_anonymous')
              : displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: SC.textPrimary,
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
          style: const TextStyle(color: SC.textMuted, fontSize: 13),
        ),
        // Online indicator — peer active in the last 2 min, not hidden.
        if (online) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: SC.online,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                AppStrings.t('online_now'),
                style: const TextStyle(
                  color: SC.online,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        // Bio (read-only) — between the PDP/name block and the stats, centred.
        if (!emptyBio) ...[
          const SizedBox(height: 14),
          Text(
            bio,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: SC.textPrimary,
              fontSize: 16.5,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Stats — posts (= gallery size) | followers | following.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _InlineStat(value: photos.length, label: 'posts'),
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
        // Action stack: Message + (Unfollow / Follow-back / Add) by relation:
        //  • I already follow them → "Unfollow".
        //  • peer follows me, I don't → "S'abonner en retour" (instant).
        //  • stranger, request already sent → "Demande envoyée".
        //  • stranger → "Ajouter" (sends a request they must accept).
        const SizedBox(height: 16),
        _GradientActionButton(
          label: AppStrings.t('profile_message'),
          icon: Icons.chat_bubble_outline,
          onTap: onMessagePeer ?? () {},
          glass: true,
        ),
        if (iFollowPeer) ...[
          const SizedBox(height: 10),
          _GradientActionButton(
            label: AppStrings.t('follow_unfollow'),
            icon: Icons.person_remove_alt_1,
            onTap: onUnfollow ?? () {},
            subdued: true,
          ),
        ] else if (peerFollowsMe) ...[
          const SizedBox(height: 10),
          _GradientActionButton(
            label: AppStrings.t('follow_back'),
            icon: Icons.person_add_alt_1,
            onTap: onFollowBack ?? () {},
          ),
        ] else if (iRequestedPeer) ...[
          const SizedBox(height: 10),
          _GradientActionButton(
            label: AppStrings.t('friendship_sent'),
            icon: Icons.schedule,
            onTap: () {},
            subdued: true,
          ),
        ] else ...[
          const SizedBox(height: 10),
          _GradientActionButton(
            label: AppStrings.t('profile_add'),
            icon: Icons.person_add_alt_1,
            onTap: onAddPeer ?? () {},
          ),
        ],
        // Centres d'intérêt (read-only) — just above the photos.
        if (interests.isNotEmpty) ...[
          const SizedBox(height: 24),
          _ProfileSectionHeader(AppStrings.t('profile_interests_section')),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final tag in interests)
                _InterestChip(label: tag, color: interestColor(tag)),
            ],
          ),
        ],
        // Read-only photo gallery — below the interests.
        if (photos.isNotEmpty) ...[
          const SizedBox(height: 24),
          _PhotoGallery(
            photos: photos,
            viewerMode: true,
            onPick: () {},
            onRemove: (_) {},
            iLikePeer: iLikePeer,
            onTogglePeerLike: onTogglePeerLike,
          ),
        ],
      ],
    );
  }
}

/// Section header used across the redesigned profile (capture-1 style):
/// a bold left-aligned title.
class _ProfileSectionHeader extends StatelessWidget {
  const _ProfileSectionHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(title, style: SCText.h2),
    );
  }
}

/// "Tes photos" — a horizontal gallery of portrait photo tiles (capture-1
/// style). On my own profile the first tile is the yellow/accent "+" add
/// CTA, followed by each photo with a delete badge; the PDP (index 0) also
/// carries the private likes badge. In viewer mode the gallery is read-only
/// (the PDP carries the like-this-peer heart). Reuses [_PhotoCell] for the
/// photo + its badges and [_AddDiscoverPhotoCta] for the add tile.
class _PhotoGallery extends StatelessWidget {
  const _PhotoGallery({
    required this.photos,
    required this.viewerMode,
    required this.onPick,
    required this.onRemove,
    this.likesCount = 0,
    this.onTapLikes,
    this.iLikePeer = false,
    this.onTogglePeerLike,
  });

  final List<String> photos;
  final bool viewerMode;
  final VoidCallback onPick;
  final void Function(String url) onRemove;
  final int likesCount;
  final VoidCallback? onTapLikes;
  final bool iLikePeer;
  final VoidCallback? onTogglePeerLike;

  static const double _height = 216;
  static const double _width = 162;

  @override
  Widget build(BuildContext context) {
    if (viewerMode && photos.isEmpty) return const SizedBox.shrink();
    final canAdd = !viewerMode && photos.length < profilePhotosMax;
    final items = <Widget>[
      if (canAdd)
        SizedBox(
          width: _width,
          child: _AddDiscoverPhotoCta(onTap: onPick),
        ),
      for (var i = 0; i < photos.length; i++)
        SizedBox(
          width: _width,
          child: _PhotoCell(
            photoUrl: photos[i],
            viewerMode: viewerMode,
            onTap: () {},
            // Delete badge on every photo on my own profile.
            onDelete: viewerMode ? null : () => onRemove(photos[i]),
            // Likes badge only on the PDP (index 0) of my own profile.
            likesCount: (!viewerMode && i == 0) ? likesCount : 0,
            onTapLikes: (!viewerMode && i == 0) ? onTapLikes : null,
            // Like-this-peer heart only on the PDP in viewer mode.
            iLikePeer: iLikePeer,
            onTogglePeerLike: (viewerMode && i == 0) ? onTogglePeerLike : null,
          ),
        ),
    ];
    return SizedBox(
      height: _height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) => items[i],
      ),
    );
  }
}

/// Inline, in-place text editor — no bottom sheet. Shows [value] (or the
/// [placeholder] when empty) as centred tappable text; tapping turns it into
/// a centred field that commits on submit (keyboard "done") or when focus
/// leaves. Reused for the name and the bio on my own profile.
class _InlineEditable extends StatefulWidget {
  const _InlineEditable({
    required this.value,
    required this.placeholder,
    required this.onSave,
    required this.maxLength,
    required this.style,
    this.maxLines = 1,
  });
  final String value;
  final String placeholder;
  final Future<void> Function(String) onSave;
  final int maxLength;

  /// Text style used both for the display text and the field — so editing
  /// looks like the static text it replaces.
  final TextStyle style;
  final int maxLines;

  @override
  State<_InlineEditable> createState() => _InlineEditableState();
}

class _InlineEditableState extends State<_InlineEditable> {
  bool _editing = false;
  bool _saving = false;
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _ctrl.text = widget.value;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  Future<void> _commit() async {
    if (!_editing || _saving) return;
    final value = _ctrl.text.trim();
    _focus.unfocus();
    setState(() => _editing = false);
    if (value != widget.value.trim()) {
      _saving = true;
      await widget.onSave(value);
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      final empty = widget.value.trim().isEmpty;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _start,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Text(
            empty ? widget.placeholder : widget.value,
            textAlign: TextAlign.center,
            maxLines: widget.maxLines,
            overflow: TextOverflow.ellipsis,
            style: empty
                ? widget.style.copyWith(
                    color: SC.textMuted, fontStyle: FontStyle.italic)
                : widget.style,
          ),
        ),
      );
    }
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      autofocus: true,
      textAlign: TextAlign.center,
      maxLength: widget.maxLength,
      maxLines: widget.maxLines,
      minLines: 1,
      cursorColor: SC.accent,
      textInputAction: TextInputAction.done,
      style: widget.style.copyWith(color: SC.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.placeholder,
        hintStyle: const TextStyle(color: SC.textMuted),
        counterText: '',
        filled: true,
        fillColor: SC.bubbleIn,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SC.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SC.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SC.accent, width: 1.5),
        ),
      ),
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) => _commit(),
    );
  }
}

/// A "centre d'intérêt" chip — a category-coloured pill. Used both on the
/// profile (display) and, with [selected], inside the picker. Tapping it on
/// my own profile opens the picker.
class _InterestChip extends StatelessWidget {
  const _InterestChip({
    required this.label,
    required this.color,
    this.selected = true,
    this.showCheck = false,
    this.onTap,
  });

  final String label;
  final Color color;

  /// Filled (true) vs faint outline (false). Display chips are always filled;
  /// the picker uses false for the unpicked options.
  final bool selected;

  /// Show a leading check — only used by the picker for picked options.
  final bool showCheck;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // "Bord blanc" style: EVERY chip is its category's solid vivid colour with
    // white text, so all colours are always visible. Selected chips get a bold
    // white border + check + shadow; unpicked ones a thin faint white border.
    final fg = Colors.white;
    return Material(
      color: color,
      elevation: selected ? 3 : 1,
      shadowColor: color.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.35),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showCheck) ...[
                Icon(Icons.check_rounded, size: 18, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "+ Ajouter" chip that opens the interest picker on my own profile.
class _InterestAddChip extends StatelessWidget {
  const _InterestAddChip({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.accent.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: SC.accent.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_rounded, color: SC.accent, size: 17),
              const SizedBox(width: 4),
              Text(
                AppStrings.t('interests_add'),
                style: const TextStyle(
                  color: SC.accent,
                  fontSize: 13.5,
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

/// The "Centres d'intérêt" section on my own profile: the picked chips plus
/// an "add" chip. Tapping either UNFOLDS the category picker inline, right
/// under the chips (no overlay / bottom sheet) — pick the tags, then tap
/// "Enregistrer" to fold it back and persist. Enforces [profileInterestsMax].
class _InterestsSection extends StatefulWidget {
  const _InterestsSection({required this.interests, required this.onSave});

  final List<String> interests;
  final Future<void> Function(List<String>)? onSave;

  @override
  State<_InterestsSection> createState() => _InterestsSectionState();
}

class _InterestsSectionState extends State<_InterestsSection> {
  late Set<String> _sel = {...widget.interests};
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _InterestsSection old) {
    super.didUpdateWidget(old);
    // Resync with the parent's saved list while folded (e.g. after a save
    // round-trip). While unfolded we keep the user's in-progress selection.
    if (!_expanded && !_sameSet(_sel, widget.interests)) {
      _sel = {...widget.interests};
    }
  }

  bool _sameSet(Set<String> a, List<String> b) =>
      a.length == b.length && a.containsAll(b);

  // Auto-persist on every tap — the picker has no mandatory "Save" step, so
  // whatever the user toggles is saved immediately. _close() flushes the final
  // state once more when folding, which also wins any rapid-tap race.
  void _toggle(String tag) {
    setState(() {
      if (_sel.contains(tag)) {
        _sel.remove(tag);
      } else if (_sel.length < profileInterestsMax) {
        _sel.add(tag);
      }
    });
    widget.onSave?.call(_sel.toList());
  }

  Future<void> _close() async {
    setState(() => _expanded = false);
    final save = widget.onSave;
    if (save != null) await save(_sel.toList());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileSectionHeader(AppStrings.t('profile_interests_section')),
        const SizedBox(height: 12),
        // The picked chips + the add/toggle chip. Tapping any of them folds
        // or unfolds the inline picker below.
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final tag in _sel)
              _InterestChip(
                label: tag,
                color: interestColor(tag),
                onTap: () => setState(() => _expanded = !_expanded),
              ),
            if (_sel.length < profileInterestsMax)
              _InterestAddChip(
                onTap: () => setState(() => _expanded = !_expanded),
              ),
          ],
        ),
        // The category picker, unfolding right here (no overlay).
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: _InlineInterestPicker(
            sel: _sel,
            onToggle: _toggle,
            onDone: _close,
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 240),
          sizeCurve: Curves.easeOutCubic,
          firstCurve: Curves.easeOut,
          secondCurve: Curves.easeIn,
        ),
      ],
    );
  }
}

/// The inline body of the interest picker: a black rounded panel where each
/// category is its OWN collapsible dropdown (coloured emoji-led header + a
/// chevron). Tapping a header unfolds that category's option chips. A live
/// counter sits on top and an "Enregistrer" fold button at the bottom — but
/// every chip tap is auto-saved by [_InterestsSection], so the button is just
/// a tidy way to fold back. Rendered inside the profile (no sheet).
class _InlineInterestPicker extends StatefulWidget {
  const _InlineInterestPicker({
    required this.sel,
    required this.onToggle,
    required this.onDone,
  });

  final Set<String> sel;
  final void Function(String tag) onToggle;
  final VoidCallback onDone;

  @override
  State<_InlineInterestPicker> createState() => _InlineInterestPickerState();
}

class _InlineInterestPickerState extends State<_InlineInterestPicker> {
  // Which category dropdowns are open. Default: open the ones that already
  // hold a picked tag, collapse the empty ones.
  late final Set<String> _open = {
    for (final cat in kInterestCategories)
      if (cat.options.any(widget.sel.contains)) cat.label,
  };

  @override
  Widget build(BuildContext context) {
    final full = widget.sel.length >= profileInterestsMax;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E0E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SC.glassBorderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Live counter row.
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${widget.sel.length}/$profileInterestsMax',
              style: TextStyle(
                color: full ? SC.accent : SC.textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 2),
          for (final cat in kInterestCategories)
            _CategoryDropdown(
              cat: cat,
              open: _open.contains(cat.label),
              onToggleOpen: () => setState(() {
                if (!_open.remove(cat.label)) _open.add(cat.label);
              }),
              sel: widget.sel,
              full: full,
              onToggle: widget.onToggle,
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: widget.onDone,
              style: FilledButton.styleFrom(
                backgroundColor: SC.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(AppStrings.t('save')),
            ),
          ),
        ],
      ),
    );
  }
}

/// One collapsible category inside [_InlineInterestPicker]: a tappable header
/// (emoji + coloured label + a "picked" count badge + rotating chevron) and,
/// when open, the category's option chips. A faint divider closes each row.
class _CategoryDropdown extends StatelessWidget {
  const _CategoryDropdown({
    required this.cat,
    required this.open,
    required this.onToggleOpen,
    required this.sel,
    required this.full,
    required this.onToggle,
  });

  final InterestCategory cat;
  final bool open;
  final VoidCallback onToggleOpen;
  final Set<String> sel;
  final bool full;
  final void Function(String tag) onToggle;

  @override
  Widget build(BuildContext context) {
    final picked = cat.options.where(sel.contains).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggleOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Text(cat.emoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
                Text(
                  cat.label,
                  style: TextStyle(
                    color: cat.color,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
                if (picked > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: cat.color.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$picked',
                      style: TextStyle(
                        color: cat.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: SC.textMuted,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final opt in cat.options)
                  _InterestChip(
                    label: opt,
                    color: interestColor(opt),
                    selected: sel.contains(opt),
                    showCheck: sel.contains(opt),
                    // When the cap is hit, leave only the already-picked chips
                    // tappable (to deselect).
                    onTap: (!sel.contains(opt) && full)
                        ? null
                        : () => onToggle(opt),
                  ),
              ],
            ),
          ),
          crossFadeState:
              open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
          sizeCurve: Curves.easeOutCubic,
        ),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
      ],
    );
  }
}

/// Small ⓘ + text row rendered under the Discover photo tile on the
/// user's own profile. Taps jump to Settings, where the "Hide me
/// from my country" toggle lives — keeps the profile clean while
/// still pointing the user at the visibility control.
class _DiscoverVisibilityHint extends StatelessWidget {
  const _DiscoverVisibilityHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, size: 14, color: SC.textMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  AppStrings.t('discover_visibility_hint'),
                  style: const TextStyle(
                    color: SC.textMuted,
                    fontSize: 12,
                    height: 1.3,
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

/// The "+" add tile that opens the gallery picker, shown as the first tile
/// of the "Tes photos" gallery on my own profile (and as the empty-state
/// when no photo has been added yet). Accent-tinted square with a centred
/// "+" badge, filling its portrait slot in the horizontal gallery.
class _AddDiscoverPhotoCta extends StatelessWidget {
  const _AddDiscoverPhotoCta({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SC.accent.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SC.accent.withValues(alpha: 0.5)),
          ),
          child: Center(
            child: Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: SC.accent,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
            ),
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
      color: SC.bubbleIn,
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
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: SC.textMuted,
                      ),
                    ),
                  )
                : Center(
                    child: Icon(
                      tappable
                          ? Icons.add_a_photo_outlined
                          : Icons.image_not_supported_outlined,
                      color: tappable ? SC.accent : SC.textMuted,
                      size: 22,
                    ),
                  ),
          ),
          if (showLikesBadge)
            Positioned(
              left: 6,
              bottom: 6,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onTapLikes,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.favorite,
                          size: 12,
                          color: Color(0xFFFF3B5C),
                        ),
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
              right: 4,
              top: 4,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onDelete,
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFFF6B6B),
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
          if (showLikeAction)
            Positioned(
              right: 4,
              bottom: 4,
              child: Material(
                color: iLikePeer
                    ? const Color(0xFFFF3B5C).withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTogglePeerLike,
                  child: Container(
                    width: 30,
                    height: 30,
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
                      color: iLikePeer ? const Color(0xFFFF3B5C) : Colors.white,
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
  const _InlineStat({required this.value, required this.label, this.onTap});

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
            color: SC.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: SC.textMuted, fontSize: 13)),
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
    return Container(width: 1, height: 28, color: const Color(0xFF2A3942));
  }
}

class _GradientActionButton extends StatelessWidget {
  const _GradientActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.subdued = false,
    this.glass = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Muted, non-emphasised style — used for the inert "Following" state.
  final bool subdued;

  /// Dark frosted-glass fill with a hairline border (same surface as the
  /// language card) and white content — used for the primary "Message"
  /// action.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    // Solid colors — glass card for the primary Message action, accent for
    // the default action, dark bubble for the subdued state.
    final bg = glass ? SC.glassStrong : (subdued ? SC.bubbleIn : SC.accent);
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: glass ? const BorderSide(color: SC.glassBorder) : BorderSide.none,
      ),
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
    // Dark frosted-glass circle (same surface as the cards) with a white
    // glyph — no blue tint.
    return Material(
      color: SC.glassStrong,
      shape: const CircleBorder(side: BorderSide(color: SC.glassBorder)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 18, color: Colors.white),
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
// ignore: unused_element  — temporarily not rendered (see profile build),
// kept intact so the "Clone my voice" card can be restored later.
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur micro: $e')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lecture audio échouée: $e')));
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
        color: SC.glassStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: enrolled ? SC.accent : SC.glassBorder),
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
                    ? SC.textMuted
                    : (enrolled ? SC.accent : SC.textPrimary),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  enrolled
                      ? AppStrings.t('voice_clone_enrolled_title')
                      : AppStrings.t('voice_clone_title'),
                  style: const TextStyle(
                    color: SC.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (locked)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: SC.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    AppStrings.t('voice_clone_ultra_badge'),
                    style: const TextStyle(
                      color: SC.accent,
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
              color: SC.textMuted,
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
                style: FilledButton.styleFrom(
                  backgroundColor: SC.accent,
                  foregroundColor: Colors.white,
                ),
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
                    color: SC.textPrimary,
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
                    color: SC.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  AppStrings.t('voice_clone_processing'),
                  style: const TextStyle(color: SC.textMuted, fontSize: 13),
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
