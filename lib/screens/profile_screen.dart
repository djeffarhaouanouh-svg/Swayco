import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics.dart';
import '../services/voice_message_api.dart';

import '../services/app_strings.dart';
import '../services/auth_service.dart';
import '../services/block_api.dart';
import '../services/chat_unread.dart';
import '../services/friend_request_unread.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/interests.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/like_api.dart';
import '../services/missions_service.dart';
import '../services/revenue_cat.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/stripe_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/glass_panel.dart';
import '../widgets/missions_ring.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
import 'chat_thread_screen.dart';
import 'friends_list_screen.dart';
import 'likes_received_screen.dart';
import 'onboarding_screen.dart';
import 'paywall_screen.dart';
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
  // Own profile: likes received per photo URL — drives each gallery photo's
  // heart badge. Likes belong to a specific photo now.
  Map<String, int> _likesByPhoto = const {};
  bool _loading = true;
  // Viewer-mode only: am I currently blocking the displayed user?
  bool _peerBlocked = false;
  // Viewer-mode only: has the displayed user blocked ME? Hides the
  // relationship actions (their edge with me is dead on their side).
  bool _peerBlockedMe = false;
  // Viewer-mode only: which of the peer's photo URLs I've liked. Drives the
  // filled heart on each of the peer's gallery photos.
  Set<String> _likedPhotoUrls = const {};
  // Viewer-mode only: directional follow state with the displayed user.
  // `_peerFollowsMe` → they added me; `_iFollowPeer` → I added them.
  bool _peerFollowsMe = false;
  bool _iFollowPeer = false;
  // Viewer-mode only: I sent the peer a friend request that's still
  // pending (they haven't accepted yet). Drives the "Demande envoyée"
  // state on the "Ajouter" button.
  bool _iRequestedPeer = false;
  Timer? _pollTimer;
  // Lets the mission celebration scroll the missions card into view.
  final GlobalKey _missionsKey = GlobalKey();

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
    MissionsService.instance.justCompleted.addListener(_onMissionFlash);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MissionsService.instance.justCompleted.removeListener(_onMissionFlash);
    _pollTimer?.cancel();
    super.dispose();
  }

  /// When a mission completes, bring the missions card into view (own profile
  /// only) so the celebration star is visible flying into its ring.
  void _onMissionFlash() {
    if (!mounted || _isViewingOther) return;
    if (MissionsService.instance.justCompleted.value == null) return;
    final ctx = _missionsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      alignment: 0.4,
    );
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
    // The peer's count would leak who liked them. Now keyed per photo URL.
    final likesByPhoto = !_isViewingOther && isSupabaseReady
        ? await LikeApi.countLikesPerPhoto(targetId)
        : const <String, int>{};
    final blocked = _isViewingOther && isSupabaseReady && deviceId.isNotEmpty
        ? await BlockApi.isBlocked(blockerId: deviceId, otherId: targetId)
        : false;
    // Has the displayed peer blocked ME? If so, hide the relationship
    // actions — the edge is dead on their side.
    var peerBlockedMe = false;
    if (_isViewingOther && isSupabaseReady && deviceId.isNotEmpty) {
      try {
        peerBlockedMe = (await BlockApi.fetchMyBlockerIds()).contains(targetId);
      } catch (_) {}
    }
    // In viewer mode we also need the set of the peer's photos I've liked so
    // each photo's heart renders in the right state on first paint.
    Set<String> likedPhotoUrls = const {};
    if (_isViewingOther && isSupabaseReady && deviceId.isNotEmpty) {
      try {
        likedPhotoUrls = await LikeApi.fetchMyLikedPhotos(deviceId);
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
      _likesByPhoto = likesByPhoto;
      _peerBlocked = blocked;
      _peerBlockedMe = peerBlockedMe;
      _likedPhotoUrls = likedPhotoUrls;
      _peerFollowsMe = peerFollowsMe;
      _iFollowPeer = iFollowPeer;
      _iRequestedPeer = iRequestedPeer;
      _loading = false;
    });
    // Refresh the onboarding-missions ring for my OWN profile (force so an edit
    // just made — bio, interests, photo — shows up and fires the shooting star).
    if (!_isViewingOther) {
      MissionsService.instance.refresh(deviceId, force: true);
    }
  }

  /// Optimistic like/unlike of one of the peer's photos (viewer mode). Roll
  /// back the local set if the DB write fails.
  Future<void> _togglePhotoLike(String photoUrl) async {
    if (!_isViewingOther ||
        _deviceId.isEmpty ||
        _targetId.isEmpty ||
        photoUrl.isEmpty) {
      return;
    }
    final wasLiked = _likedPhotoUrls.contains(photoUrl);
    setState(() {
      _likedPhotoUrls = wasLiked
          ? ({..._likedPhotoUrls}..remove(photoUrl))
          : {..._likedPhotoUrls, photoUrl};
    });
    try {
      if (wasLiked) {
        await LikeApi.unlike(
          likerId: _deviceId,
          likedId: _targetId,
          photoUrl: photoUrl,
        );
      } else {
        await LikeApi.like(
          likerId: _deviceId,
          likedId: _targetId,
          photoUrl: photoUrl,
        );
        Analytics.track('like_sent', props: {'source': 'profile'});
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _likedPhotoUrls = wasLiked
            ? {..._likedPhotoUrls, photoUrl}
            : ({..._likedPhotoUrls}..remove(photoUrl));
      });
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
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'profile', 'kind': 'follow'},
      );
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
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'profile', 'kind': 'request'},
      );
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
        currentDiscover: _remote?.discoverPhotoUrl ?? '',
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
        currentDiscover: _remote?.discoverPhotoUrl ?? '',
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

  /// Choose which gallery photo shows in Discover. Optimistically moves the
  /// cyan selection ring, then persists the pointer (no gallery reorder).
  Future<void> _setDiscoverPhoto(String url) async {
    if (_deviceId.isEmpty || url.isEmpty) return;
    final prev = _remote;
    if (prev == null || prev.discoverPhotoUrl == url) return;
    setState(() => _remote = prev.copyWith(discoverPhotoUrl: url));
    try {
      await ProfileApi.setDiscoverPhoto(deviceId: _deviceId, url: url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _remote = prev); // revert on failure
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Échec : $e')));
    }
  }

  Future<void> _saveName(String name) async {
    if (_deviceId.isEmpty) return;
    final trimmed = name.trim();
    // Ignore an empty name — a profile must keep one.
    if (trimmed.isEmpty) return;
    // No-op when the name is unchanged: don't spend a cooldown on a re-save.
    if (trimmed == (_remote?.displayName ?? '')) return;

    // Rate-limit renames to once every [profileNameChangeCooldown] (like social
    // networks). The DB trigger (migration 0044) is the real guard; this is the
    // friendly front door that tells the user how long is left instead of
    // letting the save fail with a generic error.
    final changedAt = _remote?.nameChangedAt;
    if (changedAt != null) {
      final elapsed = DateTime.now().difference(changedAt);
      if (elapsed < profileNameChangeCooldown) {
        final remaining = profileNameChangeCooldown - elapsed;
        final daysLeft = (remaining.inDays + 1)
            .clamp(1, profileNameChangeCooldown.inDays);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.t(
                'name_change_cooldown',
                args: {'days': '$daysLeft'},
              ),
            ),
          ),
        );
        return;
      }
    }

    final saved = await ProfileApi.updateMyName(
      userId: _deviceId,
      name: trimmed,
    );
    if (saved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sauvegarde échouée.')));
      return;
    }
    if (!mounted || _remote == null) return;
    // Reflect the new cooldown locally so it takes effect without a reload.
    setState(
      () => _remote = _remote!.copyWith(
        displayName: saved,
        nameChangedAt: DateTime.now(),
      ),
    );
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
    // Flag shown right of the name: the COUNTRY flag once a location is set
    // (the spoken language doesn't always match — a Brazilian speaks
    // Portuguese), else the language flag. This is NOT the language card's
    // flag, which stays the spoken language on purpose.
    final nameFlag =
        ((_remote?.city.trim().isNotEmpty ?? false)
            ? countryFlagFor(_remote?.country ?? '')
            : null) ??
        lang?.flag ??
        '';
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      // No header bar. When viewing someone else, the back button + ⋮ menu
      // float directly over the content (added to the Stack below) so the
      // whole profile reads as one continuous page. The "my profile" tab is
      // mounted in IndexedStack, so it never needed a back affordance.
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
                          // other tabs (Discover / Messages). Viewer: just
                          // clear the transparent AppBar drawn behind it, kept
                          // tight so the whole profile sits higher on screen.
                          _isViewingOther ? 36 : 12,
                          28,
                          32 + 64 + MediaQuery.paddingOf(context).bottom,
                        ),
                        children: [
                          _IdentitySection(
                            // Raw name (may be empty) — the section shows the
                            // "anonymous" fallback itself in viewer mode and
                            // an editable field on my own profile.
                            displayName: _displayName,
                            flag: nameFlag,
                            country: _remote?.country ?? '',
                            handle: _handle,
                            online: _peerOnline,
                            bio: _remote?.bio ?? '',
                            interests: _remote?.interests ?? const [],
                            photos: _remote?.photos ?? const [],
                            avatarUrl: _remote?.avatarUrl ?? '',
                            discoverPhotoUrl: _remote?.discoverPhotoUrl ?? '',
                            onSelectDiscover: _setDiscoverPhoto,
                            counts: _counts,
                            likesByPhoto: _likesByPhoto,
                            viewerMode: _isViewingOther,
                            peerFollowsMe: _peerFollowsMe,
                            iFollowPeer: _iFollowPeer,
                            iRequestedPeer: _iRequestedPeer,
                            peerBlocked: _peerBlocked,
                            peerBlockedMe: _peerBlockedMe,
                            likedPhotoUrls: _likedPhotoUrls,
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
                            onToggleBlock: _toggleBlock,
                            onTogglePhotoLike: _togglePhotoLike,
                            onMessagePeer: _openChatWithPeer,
                          ),
                          const SizedBox(height: 20),
                          _LanguageCard(
                            language: lang,
                            showCallWarning: !_isViewingOther,
                          ),
                          if (!_isViewingOther) ...[
                            // "Mon abonnement" — directly under the spoken-
                            // language card. Web (Stripe) + native with
                            // RevenueCat configured; hidden on native without it
                            // (would fall back to forbidden Stripe).
                            if (kIsWeb || RevenueCat.isConfigured) ...[
                              const SizedBox(height: 16),
                              _MySubscriptionSection(
                                currentTier:
                                    _remote?.subscriptionTier ?? 'free',
                              ),
                            ],
                            // Missions ring — earn call minutes by completing
                            // onboarding quests. Sits above the referral block.
                            const SizedBox(height: 20),
                            MissionsCard(key: _missionsKey),
                            // Referral section — sits between the language card
                            // (above) and "Mon abonnement" (below): invite 3
                            // friends, earn 15 min of translated calls.
                            const SizedBox(height: 20),
                            const _InviteFriendsSection(),
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
                          ],
                        ],
                      ),
              ),
            ),
            // Floating controls over the content — no header bar. Back on the
            // left, the report/block ⋮ menu on the right; both sit
            // transparently on top of the scrolling profile.
            if (_isViewingOther)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        GlassIconButton(
                          icon: Icons.arrow_back_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        const Spacer(),
                        PopupMenuButton<String>(
                          tooltip: AppStrings.t('tooltip_more'),
                          icon: const Icon(
                            Icons.more_vert,
                            color: SC.textPrimary,
                          ),
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
                                    style: const TextStyle(
                                      color: Color(0xFFE53935),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem<String>(
                              value: 'block',
                              child: Row(
                                children: [
                                  Icon(
                                    _peerBlocked
                                        ? Icons.lock_open
                                        : Icons.block,
                                    size: 18,
                                    color: const Color(0xFFE53935),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    AppStrings.t(
                                      _peerBlocked ? 'unblock' : 'block',
                                    ),
                                    style: const TextStyle(
                                      color: Color(0xFFE53935),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // When viewing someone else's profile this screen is a route
            // pushed on top of [RootShell], so the shell's floating nav bar
            // is hidden. Re-render it here and route taps back to the shell.
            if (_isViewingOther)
              Positioned(
                left: 52,
                right: 52,
                bottom: MediaQuery.paddingOf(context).bottom +
                    GlassNavBar.floatBottom,
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
/// number one piece of the live engine's UX feedback on this surface, so the
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
              AppStrings.t(
                kIsWeb ? 'credits_low_hint' : 'credits_low_hint_native',
              ),
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
/// Referral section on the user's own profile (between the language card and
/// "Mon abonnement"): invite 3 friends with your link, earn 15 min. Fetches
/// the referral code + signed-up count itself and opens the OS share sheet.
class _InviteFriendsSection extends StatefulWidget {
  const _InviteFriendsSection();

  @override
  State<_InviteFriendsSection> createState() => _InviteFriendsSectionState();
}

class _InviteFriendsSectionState extends State<_InviteFriendsSection> {
  String _code = '';
  int _referrals = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final uid = AuthService.currentUserId;
    if (uid.isEmpty) return;
    final p = await ProfileApi.fetchById(uid);
    final n = await ProfileApi.countReferrals(uid);
    if (!mounted) return;
    setState(() {
      _code = p?.referralCode ?? '';
      _referrals = n;
    });
  }

  Future<void> _share() async {
    final box = context.findRenderObject() as RenderBox?;
    final link = _code.isEmpty
        ? 'https://www.swayco.fr'
        : 'https://www.swayco.fr/?ref=$_code';
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: AppStrings.t('invite_share_text', args: {'link': link}),
          subject: AppStrings.t('invite_friend'),
          sharePositionOrigin: box != null
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        ),
      );
    } catch (_) {
      // User cancelled or sharing unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _referrals % 3;
    return GlassPanel(
      borderRadius: 20,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SC.accent.withValues(alpha: 0.15),
                ),
                child: const Icon(
                  Icons.group_add_rounded,
                  color: SC.accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  AppStrings.t('invite_bonus_title'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            AppStrings.t('invite_bonus_body'),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            AppStrings.t(
              'invite_bonus_progress',
              args: {'count': '$progress', 'total': '3'},
            ),
            style: const TextStyle(
              color: SC.accent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _share,
              style: FilledButton.styleFrom(
                backgroundColor: SC.accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: Text(AppStrings.t('invite_bonus_share_cta')),
            ),
          ),
        ],
      ),
    );
  }
}

class _MySubscriptionSection extends StatelessWidget {
  const _MySubscriptionSection({required this.currentTier});

  final String currentTier;

  /// Tier ladder, used only to decide whether the user has any upgrade
  /// above their current tier. Ultra users have none, so the whole
  /// "Mon abonnement" row disappears.
  static const List<String> _ladder = ['free', 'plus', 'ultra_plus'];

  @override
  Widget build(BuildContext context) {
    final i = _ladder.indexOf(currentTier);
    final rank = i < 0 ? 0 : i;
    final hasUpgrades = _ladder.skip(rank + 1).isNotEmpty;
    if (!hasUpgrades) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: SC.glassStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SC.glassBorder),
      ),
      padding: const EdgeInsets.all(4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          // Tapping the row slides the paywall up from the bottom as a
          // modal sheet instead of expanding the pricing cards inline.
          onTap: () => showPaywallSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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
                const Icon(Icons.chevron_right_rounded, color: SC.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the Stripe Customer Portal. Shown on the credits card when
/// the user is already Pro / Ultra so they can cancel / change card /
/// upgrade / downgrade. Web-only.
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
    final langName = language != null
        ? AppStrings.t('lang_name_${language!.code}')
        : '';
    final label = language != null
        ? AppStrings.t('profile_speaks', args: {'lang': langName})
        : AppStrings.t('profile_no_language');
    final warning = (showCallWarning && language != null)
        ? AppStrings.t(
            'profile_call_language_warning',
            args: {'lang': langName},
          )
        : null;
    return GlassPanel(
      borderRadius: 16,
      color: SC.glassStrong,
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
    this.flag = '',
    this.country = '',
    required this.handle,
    this.online = false,
    required this.bio,
    required this.interests,
    required this.photos,
    required this.avatarUrl,
    this.discoverPhotoUrl = '',
    this.onSelectDiscover,
    required this.counts,
    required this.likesByPhoto,
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
    this.peerBlocked = false,
    this.peerBlockedMe = false,
    this.onFollowBack,
    this.onAddPeer,
    this.onUnfollow,
    this.onToggleBlock,
    this.likedPhotoUrls = const {},
    this.onTogglePhotoLike,
    this.onMessagePeer,
  });

  final String displayName;

  /// Country flag emoji shown right of the name ('' to hide).
  final String flag;

  /// The user's stored country name (e.g. 'Japon'). Selects which interests
  /// taxonomy the own-profile picker shows. Empty in viewer mode.
  final String country;
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

  /// Which gallery photo currently shows in Discover — gets the cyan ring.
  final String discoverPhotoUrl;

  /// Own profile: pick which gallery photo is the Discover photo (by URL).
  final void Function(String url)? onSelectDiscover;
  final FriendshipCounts counts;

  /// Likes received per photo URL. Only shown on my own profile (private).
  final Map<String, int> likesByPhoto;

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

  /// Viewer-mode only: have I blocked the displayed peer? When true the
  /// action stack collapses to a single "Débloquer" button — the follow
  /// relation and Message CTA are meaningless on a profile I've cut off.
  final bool peerBlocked;

  /// Viewer-mode only: has the displayed peer blocked ME? When true the
  /// relationship actions (Unfollow / Follow-back / Add) are hidden — the
  /// edge is dead on their side, so offering to manage it is misleading.
  final bool peerBlockedMe;

  /// Viewer-mode only: follow the peer back (instant abonnement).
  final VoidCallback? onFollowBack;

  /// Viewer-mode only: send a friend request to a stranger ("Ajouter").
  final VoidCallback? onAddPeer;

  /// Viewer-mode only: unfollow the peer (removes them from my friends).
  final VoidCallback? onUnfollow;

  /// Viewer-mode only: block / unblock the displayed peer. Drives the
  /// "Débloquer" action button shown while [peerBlocked] is true.
  final VoidCallback? onToggleBlock;

  /// Viewer-mode only: the peer's photo URLs I've liked. Drives the filled
  /// heart on each of their gallery photos.
  final Set<String> likedPhotoUrls;

  /// Viewer-mode only: like/unlike one of the peer's photos by URL.
  final void Function(String photoUrl)? onTogglePhotoLike;

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
          // Viewer mode: a green presence dot on the lower-right of the PDP
          // when the peer is online (replaces the old "en ligne" text line).
          if (!editable && online)
            Positioned(
              right: 10,
              bottom: 10,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: SC.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: SC.bg, width: 3),
                ),
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
        // Header — "Ton profil" title with the settings gear pinned to the
        // top-right corner of the page.
        Row(
          children: [
            Expanded(
              child: Text(
                AppStrings.t('onb_profile_title'),
                style: SCText.h1,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
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
                  if (flag.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(flag, style: const TextStyle(fontSize: 18)),
                  ],
                ],
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
                      border: Border.all(
                        color: SC.accent.withValues(alpha: 0.6),
                      ),
                    ),
                    child: const Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: SC.accent,
                    ),
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
        // Bio stays fully centred under the name; the +20 reward hint floats
        // at the far right of the same line, nudged up — it lines up with the
        // Interests / Your photos +20 badges below and never pushes the bio
        // down or off-centre. Symmetric side padding keeps a long bio clear
        // of the hint while preserving the centring.
        Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 44),
              child: SizedBox(
                width: double.infinity,
                child: _InlineEditable(
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
              ),
            ),
            const Positioned(right: 0, top: -4, child: _RewardHint()),
          ],
        ),
        const SizedBox(height: 16),
        // Stats — posts | followers | following — centred across the full
        // width (the settings gear now lives in the top-right header).
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _InlineStat(
              value: photos.length,
              label: AppStrings.t('profile_posts').toLowerCase(),
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
        const SizedBox(height: 24),
        // Centres d'intérêt — picked chips + an "add" chip; tapping either
        // unfolds the category picker inline, right under the chips (no
        // overlay), then folds back when you're done. Shown ABOVE the photos.
        _InterestsSection(
          interests: interests,
          onSave: onEditInterests,
          country: country,
        ),
        const SizedBox(height: 24),
        // "Tes photos (n)" + horizontal gallery (add tile first, then photos).
        _ProfileSectionHeader(photosTitle, trailing: const _RewardHint()),
        const SizedBox(height: 12),
        _PhotoGallery(
          photos: photos,
          viewerMode: false,
          onPick: onPickPhoto,
          onRemove: onRemovePhoto,
          likesByPhoto: likesByPhoto,
          onTapLikes: onTapLikes,
          discoverPhotoUrl: discoverPhotoUrl,
          onSelectDiscover: onSelectDiscover,
        ),
        const SizedBox(height: 10),
        // ⓘ hint — taps jump to Settings where "Me cacher de mon pays" lives.
        _DiscoverVisibilityHint(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
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
        // Centred name + flag + handle. Falls back to the anonymous label
        // when the peer has no display name set.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
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
            ),
            if (flag.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(flag, style: const TextStyle(fontSize: 18)),
            ],
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
        // (Online presence is now a green dot on the PDP — see _pdpBubble.)
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
            _InlineStat(
              value: photos.length,
              label: AppStrings.t('profile_posts').toLowerCase(),
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
        // Action stack. When I've blocked this peer the whole stack
        // collapses to a single "Débloquer" CTA — the follow relation and
        // Message button would otherwise read as wrong ("Se désabonner" /
        // "Message") on a profile I've deliberately cut off.
        // Otherwise: Message + (Unfollow / Follow-back / Add) by relation:
        //  • I already follow them → "Unfollow".
        //  • peer follows me, I don't → "S'abonner en retour" (instant).
        //  • stranger, request already sent → "Demande envoyée".
        //  • stranger → "Ajouter" (sends a request they must accept).
        const SizedBox(height: 16),
        if (peerBlocked) ...[
          _GradientActionButton(
            label: AppStrings.t('unblock'),
            icon: Icons.lock_open,
            onTap: onToggleBlock ?? () {},
          ),
        ] else ...[
          _GradientActionButton(
            label: AppStrings.t('profile_message'),
            icon: Icons.chat_bubble_outline,
            onTap: onMessagePeer ?? () {},
            glass: true,
          ),
          // The peer blocked me → their edge with me is dead on their side,
          // so hide the relationship actions (no Unfollow / Follow-back /
          // Add). Only the Message button stays above.
          if (!peerBlockedMe) ...[
            if (iFollowPeer) ...[
              const SizedBox(height: 10),
              _GradientActionButton(
                label: AppStrings.t('follow_unfollow'),
                icon: Icons.person_remove_alt_1,
                onTap: onUnfollow ?? () {},
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
          ],
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
                _InterestChip(
                  label: tag,
                  color: interestColor(tag),
                ),
            ],
          ),
        ],
        // Read-only photos — always shown under their own header: the gallery
        // when the peer has photos, else an "Aucune photo" placeholder.
        const SizedBox(height: 24),
        _ProfileSectionHeader(AppStrings.t('profile_photos_peer')),
        const SizedBox(height: 12),
        if (photos.isNotEmpty)
          _PhotoGallery(
            photos: photos,
            viewerMode: true,
            onPick: () {},
            onRemove: (_) {},
            likedPhotoUrls: likedPhotoUrls,
            onTogglePhotoLike: onTogglePhotoLike,
          )
        else
          const _EmptyPhotosPlaceholder(),
      ],
    );
  }
}

/// Section header used across the redesigned profile (capture-1 style):
/// a bold left-aligned title.
class _ProfileSectionHeader extends StatelessWidget {
  const _ProfileSectionHeader(this.title, {this.trailing});
  final String title;

  /// Optional widget pinned to the right of the title (e.g. a cyan "+20"
  /// reward hint on the photos / interests sections).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: SCText.h2)),
        ?trailing,
      ],
    );
  }
}

/// Empty-state on a peer's profile when they have no photos: a faint bordered
/// box with a camera icon and "Aucune photo", shown under the Photos header.
class _EmptyPhotosPlaceholder extends StatelessWidget {
  const _EmptyPhotosPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SC.glassBorder),
        color: Colors.white.withValues(alpha: 0.02),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.photo_camera_outlined,
            size: 34,
            color: SC.textMuted,
          ),
          const SizedBox(height: 10),
          Text(
            AppStrings.t('profile_no_photos'),
            style: const TextStyle(color: SC.textMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// Small cyan "+20" reward hint shown on the right of a section header to
/// nudge the user to complete it.
class _RewardHint extends StatelessWidget {
  const _RewardHint();
  @override
  Widget build(BuildContext context) {
    return const Text(
      '+20',
      style: TextStyle(
        color: SC.accent,
        fontSize: 16,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

/// Full-screen overlay for profile photos. Swipe or use the side arrows to
/// move between several photos; pinch to zoom; the ✕ in the photo's top-right
/// corner (or a tap on the backdrop) dismisses. On the own profile a "set as
/// Discover photo" button sets whichever photo is currently in view.
Future<void> showPhotoViewer(
  BuildContext context, {
  required List<String> photos,
  required int index,
  bool viewerMode = false,
  void Function(String url)? onSetDiscover,
}) {
  if (photos.isEmpty) return Future<void>.value();
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim, _) => _PhotoViewer(
        photos: photos,
        initialIndex: index.clamp(0, photos.length - 1),
        viewerMode: viewerMode,
        onSetDiscover: onSetDiscover,
      ),
      // Fade + grow-in (scale from 90%) instead of a flat fade, so the photo
      // eases open instead of popping.
      transitionsBuilder: (ctx, anim, _, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.photos,
    required this.initialIndex,
    this.viewerMode = false,
    this.onSetDiscover,
  });
  final List<String> photos;
  final int initialIndex;
  final bool viewerMode;
  final void Function(String url)? onSetDiscover;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pc = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.photos.length - 1);
    if (next != _index) {
      _pc.animateToPage(
        next,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _circleBtn(IconData icon, VoidCallback? onTap, {double size = 36}) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.25 : 1,
        // Frosted-glass circle (blur + faint white tint), not a flat black fill.
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22),
                ),
              ),
              child: Icon(icon, color: Colors.white, size: size * 0.55),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final multi = widget.photos.length > 1;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.78),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pc,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (ctx, i) => GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: size.width - 28,
                        maxHeight: size.height * 0.78,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: InteractiveViewer(
                          minScale: 1,
                          maxScale: 4,
                          child: Image.network(
                            widget.photos[i],
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Padding(
                              padding: EdgeInsets.all(40),
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: SC.textMuted,
                                size: 48,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // ✕ in the photo's top-right corner.
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _circleBtn(
                        Icons.close_rounded,
                        () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Side arrows when there's more than one photo.
          if (multi) ...[
            Positioned(
              left: 6,
              top: 0,
              bottom: 0,
              child: Center(
                child: _circleBtn(
                  Icons.chevron_left_rounded,
                  _index > 0 ? () => _go(-1) : null,
                  size: 44,
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 0,
              bottom: 0,
              child: Center(
                child: _circleBtn(
                  Icons.chevron_right_rounded,
                  _index < widget.photos.length - 1 ? () => _go(1) : null,
                  size: 44,
                ),
              ),
            ),
          ],
          if (!widget.viewerMode && widget.onSetDiscover != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: bottom + 28,
              child: GestureDetector(
                onTap: () {
                  widget.onSetDiscover!(widget.photos[_index]);
                  Navigator.of(context).pop();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: SC.accent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    AppStrings.t('set_discover_photo'),
                    style: const TextStyle(
                      color: SC.bgDeep,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
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
    this.likesByPhoto = const {},
    this.onTapLikes,
    this.likedPhotoUrls = const {},
    this.onTogglePhotoLike,
    this.discoverPhotoUrl = '',
    this.onSelectDiscover,
  });

  final List<String> photos;
  final bool viewerMode;
  final VoidCallback onPick;
  final void Function(String url) onRemove;
  // Own profile: URL of the Discover photo (cyan ring) + select-by-tap.
  final String discoverPhotoUrl;
  final void Function(String url)? onSelectDiscover;
  // Own profile: likes received per photo URL.
  final Map<String, int> likesByPhoto;
  final VoidCallback? onTapLikes;
  // Viewer mode: the peer's photo URLs I've liked.
  final Set<String> likedPhotoUrls;
  // Viewer mode: like/unlike one of the peer's photos by URL.
  final void Function(String photoUrl)? onTogglePhotoLike;

  // Portrait tiles (3:4) laid out three-per-row, Instagram-style.
  static const double _aspect = 216 / 162; // height / width
  static const double _spacing = 8;
  static const int _columns = 3;
  // Cap the tile size so wide (desktop / web) layouts show small thumbnails
  // that wrap across the row, instead of three giant images. Phones stay
  // below this cap, so they keep exactly three per row.
  static const double _maxTile = 150;

  @override
  Widget build(BuildContext context) {
    if (viewerMode && photos.isEmpty) return const SizedBox.shrink();
    final canAdd = !viewerMode && photos.length < profilePhotosMax;

    // Own profile: a single horizontal, scrollable row of LARGER tiles (the
    // add-tile first) — your photos stack on one line you swipe through,
    // instead of the small 3-up grid used on someone else's profile.
    if (!viewerMode) {
      const double tileWidth = 160;
      final double tileHeight = tileWidth * _aspect;
      final count = (canAdd ? 1 : 0) + photos.length;
      return SizedBox(
        height: tileHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.zero,
          itemCount: count,
          separatorBuilder: (_, _) => const SizedBox(width: _spacing),
          itemBuilder: (context, index) {
            if (canAdd && index == 0) {
              return SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _AddDiscoverPhotoCta(onTap: onPick),
              );
            }
            final url = photos[canAdd ? index - 1 : index];
            return SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: _PhotoCell(
                photoUrl: url,
                viewerMode: false,
                isDiscover:
                    discoverPhotoUrl.isNotEmpty &&
                    url.split('?').first == discoverPhotoUrl.split('?').first,
                onTap: () => showPhotoViewer(
                  context,
                  photos: photos,
                  index: canAdd ? index - 1 : index,
                  onSetDiscover: onSelectDiscover,
                ),
                onDelete: () => onRemove(url),
                likesCount: likesByPhoto[url] ?? 0,
                onTapLikes: onTapLikes,
                iLikePeer: false,
                onTogglePeerLike: null,
              ),
            );
          },
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Phone: three per row (width / 3). Desktop: the three-up width blows
        // past [_maxTile], so clamp to it and let the Wrap flow more, smaller
        // tiles across the width.
        final threeUp =
            (constraints.maxWidth - _spacing * (_columns - 1)) / _columns;
        final tileWidth = threeUp > _maxTile ? _maxTile : threeUp;
        final tileHeight = tileWidth * _aspect;
        final cells = <Widget>[
          if (canAdd)
            SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: _AddDiscoverPhotoCta(onTap: onPick),
            ),
          for (var i = 0; i < photos.length; i++)
            SizedBox(
              width: tileWidth,
              height: tileHeight,
              child: _PhotoCell(
                photoUrl: photos[i],
                viewerMode: viewerMode,
                // Cyan ring on the photo currently shown in Discover.
                isDiscover:
                    !viewerMode &&
                    discoverPhotoUrl.isNotEmpty &&
                    photos[i].split('?').first ==
                        discoverPhotoUrl.split('?').first,
                // Tapping a photo opens it full-screen (overlay).
                onTap: () => showPhotoViewer(
                  context,
                  photos: photos,
                  index: i,
                  viewerMode: true,
                ),
                // Delete badge on every photo on my own profile.
                onDelete: viewerMode ? null : () => onRemove(photos[i]),
                // Per-photo likes badge on each of my own photos.
                likesCount: viewerMode ? 0 : (likesByPhoto[photos[i]] ?? 0),
                onTapLikes: viewerMode ? null : onTapLikes,
                // Per-photo like heart on each of the peer's photos (viewer).
                iLikePeer: likedPhotoUrls.contains(photos[i]),
                onTogglePeerLike: viewerMode && onTogglePhotoLike != null
                    ? () => onTogglePhotoLike!(photos[i])
                    : null,
              ),
            ),
        ];
        return Wrap(spacing: _spacing, runSpacing: _spacing, children: cells);
      },
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
                    color: SC.textMuted,
                    fontStyle: FontStyle.italic,
                  )
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
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
    this.shape,
    this.selected = true,
    this.showCheck = false,
    this.onTap,
  });

  final String label;
  final Color color;

  /// Per-category silhouette. Null → derived from the label's category
  /// (used by the read-only display chips, which only know the stored label).
  final InterestShape? shape;

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
    final s = shape ?? interestShape(label);
    final outer = interestShapeBorder(s);
    final bordered = interestShapeBorder(
      s,
      side: BorderSide(
        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.35),
        width: selected ? 2 : 1,
      ),
    );
    final inner = InkWell(
      customBorder: outer,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: ShapeDecoration(shape: bordered),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showCheck) ...[
              Icon(Icons.check_rounded, size: 18, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              interestLabel(label),
              style: TextStyle(
                color: fg,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
    return Material(
      color: color,
      elevation: selected ? 3 : 1,
      shadowColor: color.withValues(alpha: 0.6),
      shape: outer,
      child: inner,
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
  const _InterestsSection({
    required this.interests,
    required this.onSave,
    this.country = '',
  });

  final List<String> interests;
  final Future<void> Function(List<String>)? onSave;

  /// The user's country — selects which interests taxonomy the picker shows.
  final String country;

  @override
  State<_InterestsSection> createState() => _InterestsSectionState();
}

class _InterestsSectionState extends State<_InterestsSection> {
  late Set<String> _sel = {...widget.interests};
  bool _expanded = false;
  // Shared so a tap on the chips above isn't treated as "outside" the picker:
  // otherwise tapping the open "Add" chip would fire the picker's
  // onTapOutside (close) AND the chip's onTap (reopen) → it never closes.
  final Object _pickerGroup = Object();

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

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    if (!_expanded) return;
    // Once the picker unfolds, scroll it up to the top of the viewport so the
    // pins are fully in view (it would otherwise open below the fold).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileSectionHeader(
          AppStrings.t('profile_interests_section'),
          trailing: const _RewardHint(),
        ),
        const SizedBox(height: 12),
        // The picked chips + the add/toggle chip. Tapping any of them folds
        // or unfolds the inline picker below. In the same TapRegion group as
        // the picker so tapping a chip while open doesn't count as "outside".
        TapRegion(
          groupId: _pickerGroup,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final tag in _sel)
                _InterestChip(
                  label: tag,
                  color: interestColor(tag),
                  onTap: _toggleExpanded,
                ),
              if (_sel.length < profileInterestsMax)
                _InterestAddChip(onTap: _toggleExpanded),
            ],
          ),
        ),
        // The category picker, unfolding right here (no overlay). A tap
        // anywhere outside the panel folds it back (auto-saved already).
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: TapRegion(
            groupId: _pickerGroup,
            onTapOutside: (_) {
              if (_expanded) _close();
            },
            child: _InlineInterestPicker(
              sel: _sel,
              onToggle: _toggle,
              onDone: _close,
              country: widget.country,
            ),
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

/// The inline body of the interest picker: a black rounded panel that is a
/// CAROUSEL — one page per category. Swipe sideways (or tap a dot) to move
/// between categories; each page shows that category's coloured header and its
/// option chips. A live counter sits on top and an "Enregistrer" fold button
/// at the bottom — but every chip tap is auto-saved by [_InterestsSection], so
/// the button is just a tidy way to fold back. Rendered inside the profile.
class _InlineInterestPicker extends StatefulWidget {
  const _InlineInterestPicker({
    required this.sel,
    required this.onToggle,
    required this.onDone,
    this.country = '',
  });

  final Set<String> sel;
  final void Function(String tag) onToggle;
  final VoidCallback onDone;

  /// The user's country — selects which interests taxonomy to display.
  final String country;

  @override
  State<_InlineInterestPicker> createState() => _InlineInterestPickerState();
}

class _InlineInterestPickerState extends State<_InlineInterestPicker> {
  final PageController _pager = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _goTo(int i) => _pager.animateToPage(
    i,
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
  );

  @override
  Widget build(BuildContext context) {
    final full = widget.sel.length >= profileInterestsMax;
    final cats = interestCategoriesFor(widget.country);
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
          const SizedBox(height: 4),
          // One page per category — swipe sideways to switch category.
          SizedBox(
            height: 248,
            child: PageView.builder(
              controller: _pager,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: cats.length,
              itemBuilder: (ctx, i) => _CategoryPage(
                cat: cats[i],
                sel: widget.sel,
                full: full,
                onToggle: widget.onToggle,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Page dots, coloured to the active category; tap to jump.
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < cats.length; i++) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _goTo(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? cats[i].color
                            : SC.textMuted.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  if (i != cats.length - 1) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
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

/// One carousel page of [_InlineInterestPicker]: a single category — coloured
/// emoji-led header + a "picked" count badge, then that category's option
/// chips (wrapping, scrollable vertically if they overflow the page).
class _CategoryPage extends StatelessWidget {
  const _CategoryPage({
    required this.cat,
    required this.sel,
    required this.full,
    required this.onToggle,
  });

  final InterestCategory cat;
  final Set<String> sel;
  final bool full;
  final void Function(String tag) onToggle;

  @override
  Widget build(BuildContext context) {
    final picked = cat.options.where(sel.contains).length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(cat.emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                interestLabel(cat.label),
                style: TextStyle(
                  color: cat.color,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
              if (picked > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
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
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final opt in cat.options)
                    _InterestChip(
                      label: opt,
                      // Use THIS category's colour — interestColor() takes the
                      // first matching category, so a label shared by two
                      // categories (e.g. K-pop / J-pop) would otherwise show
                      // the other category's colour inside this page.
                      color: cat.color,
                      shape: cat.shape,
                      selected: sel.contains(opt),
                      showCheck: sel.contains(opt),
                      // When the cap is hit, leave only the already-picked
                      // chips tappable (to deselect).
                      onTap: (!sel.contains(opt) && full)
                          ? null
                          : () => onToggle(opt),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Build a rich span from [raw], rendering any run wrapped in `**…**` in the
/// cyan accent (the markers are stripped). Used to highlight a few keywords in
/// the two-sentence Discover visibility hint, in every language.
TextSpan _highlightKeywords(String raw) {
  final parts = raw.split('**');
  return TextSpan(
    children: [
      for (var i = 0; i < parts.length; i++)
        TextSpan(
          text: parts[i],
          style: i.isOdd
              ? const TextStyle(color: SC.accent, fontWeight: FontWeight.w600)
              : null,
        ),
    ],
  );
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
    // The hint is two sentences joined by "\n". Show each on its own row with
    // its own ⓘ, and put the short "framed photo" sentence (always the 2nd)
    // first — hence the reversed order.
    final sentences = AppStrings.t(
      'discover_visibility_hint',
    ).split('\n').where((s) => s.trim().isNotEmpty).toList().reversed.toList();
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < sentences.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(
                          Icons.info_outline,
                          size: 14,
                          color: SC.textMuted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        // Keywords wrapped in **…** in app_strings render cyan.
                        child: Text.rich(
                          _highlightKeywords(sentences[i]),
                          style: const TextStyle(
                            color: SC.textMuted,
                            fontSize: 12,
                            height: 1.35,
                          ),
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
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 28,
              ),
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
    this.isDiscover = false,
  });

  final String? photoUrl;
  final bool viewerMode;
  final VoidCallback onTap;

  /// True for the gallery photo currently shown in Discover — draws a thin
  /// cyan ring around the tile.
  final bool isDiscover;

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
            // A real photo is always tappable to open it full-screen — on a
            // peer's profile (viewer mode) too, not just my own. Only the
            // empty "add" cell is gated to my own profile (tappable).
            onTap: (hasPhoto || tappable) ? onTap : null,
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
          // Thin cyan ring marking the photo currently shown in Discover.
          if (isDiscover)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: SC.accent, width: 4),
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
        // Count up to the value when it first appears / changes.
        TweenAnimationBuilder<int>(
          tween: IntTween(begin: 0, end: value),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Text(
            '$v',
            style: const TextStyle(
              color: SC.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
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
    // Scale the icon+label down to fit when a translation is long (German /
    // Russian / katakana run wider) instead of overflowing.
    final content = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
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
    );
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

    // Primary "Message" action → REAL frosted glass (BackdropFilter blur), like
    // the header / nav glass; accent fill for the default action, dark bubble
    // for the subdued "Following" state.
    if (glass) {
      return Pressable(
        bounce: true,
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                color: SC.glassStrong,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: SC.glassBorder),
              ),
              padding: padding,
              alignment: Alignment.center,
              child: content,
            ),
          ),
        ),
      );
    }
    return Pressable(
      bounce: true,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: subdued ? SC.bubbleIn : SC.accent,
          borderRadius: BorderRadius.circular(999),
        ),
        padding: padding,
        alignment: Alignment.center,
        child: content,
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
    // Real glass circle — the same widget as the header back/call buttons
    // (BackdropFilter glass + spring bounce), not a flat fill.
    return Tooltip(
      message: tooltip,
      child: GlassIconButton(
        icon: icon,
        onTap: onTap,
        size: 44,
        iconSize: 21,
        // Bigger, marked grow-then-settle pop on tap (like the nav bar).
        popScale: 1.25,
      ),
    );
  }
}

/// Ultra-only "Clone ma voix" card. Lets the user record ~30 s of
/// audio, ships it to /voice/enroll and flips into a green
/// "Voix clonée ✓" state once the backend confirms.
///
/// Tap to start recording → tap again to send → spinner while
/// the voice provider processes → state updates. Re-enrolment is supported
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

  /// Recommended sample length for the cloning provider. Below 20 s the
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
      // compromise that the voice provider handles cleanly.
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
