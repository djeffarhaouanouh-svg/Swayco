import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/analytics.dart';

import '../services/app_strings.dart';
import '../services/block_api.dart';
import '../services/chat_unread.dart';
import '../services/friend_request_unread.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/age_range.dart';
import '../services/fact_emojis.dart';
import '../services/interests.dart';
import '../services/job_sectors.dart';
import '../services/languages.dart';
import '../services/locations.dart';
import '../services/looking_for.dart';
import '../services/like_api.dart';
import '../services/match_celebration.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../services/zodiac.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/interest_chip.dart';
import '../widgets/match_overlay.dart';
import '../widgets/pressable.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_dialog.dart';
import '../widgets/translated_profile_text.dart';
import '../widgets/wheel_picker_sheet.dart';
import 'chat_thread_screen.dart';
// L'aperçu "ma carte" vit dans le Discover : il réutilise le widget de carte
// du feed pour que l'aperçu soit le rendu réel, pas une copie qui dérive.
import 'discover_screen.dart' show MyCardPreviewScreen;
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
  const ProfileScreen({super.key, this.userId, this.preview = false});

  /// When non-null, render the profile of the given Supabase auth user id
  /// in read-only "viewer" mode rather than my own profile.
  final String? userId;

  /// Aperçu de MON profil tel que les autres le voient : rendu viewer sur mes
  /// propres données, mais sans les actions (Message / Matcher / bloquer) ni le
  /// menu ⋮ — juste un bouton retour pour fermer.
  final bool preview;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver {
  String _deviceId = '';
  RemoteProfile? _remote;
  ProfileSnapshot? _local;
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
  // Viewer-mode only: where the two of us stand.
  //   `_matched`     → we liked each other: it's a match.
  //   `_iLiked`      → my like is waiting for their answer.
  //   `_peerLikedMe` → their like is waiting for mine (one tap = match).
  bool _matched = false;
  bool _iLiked = false;
  bool _peerLikedMe = false;
  Timer? _pollTimer;

  bool get _isViewingOther => widget.userId != null || widget.preview;
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

    // TOUT EN PARALLÈLE. Ces sept lectures s'attendaient les unes les autres :
    // sept allers-retours réseau bout à bout, soit plusieurs secondes d'écran
    // vide sur une connexion mobile ordinaire. Aucune ne dépend du résultat
    // d'une autre — seule l'identité de l'appareil, obtenue au-dessus, leur est
    // nécessaire. Elles partent donc ensemble : le temps d'attente devient
    // celui de la plus lente, pas la somme.
    final viewer = _isViewingOther;
    final canQuery = isSupabaseReady && deviceId.isNotEmpty;
    final results = await Future.wait<Object?>([
      // Cache local (mon profil seulement) : instantané, mais il attendait
      // quand même son tour derrière le réseau.
      viewer ? Future<Object?>.value() : UserPrefs.loadProfile(),
      isSupabaseReady
          ? ProfileApi.fetchById(targetId)
          : Future<Object?>.value(),
      // Les likes reçus n'ont de sens que sur mon profil : le compte d'un pair
      // trahirait qui l'a liké.
      !viewer && isSupabaseReady
          ? LikeApi.countLikesPerPhoto(targetId)
          : Future<Object?>.value(const <String, int>{}),
      viewer && canQuery
          ? BlockApi.isBlocked(blockerId: deviceId, otherId: targetId)
          : Future<Object?>.value(false),
      // Ce pair m'a-t-il bloqué ? Si oui, les actions de match disparaissent —
      // l'arête est morte de son côté.
      viewer && canQuery
          ? BlockApi.fetchMyBlockerIds().catchError(
              (_) => <String>{},
            )
          : Future<Object?>.value(<String>{}),
      // Ses photos que j'ai likées, pour que chaque cœur soit dans le bon état
      // dès le premier rendu.
      viewer && canQuery
          ? LikeApi.fetchMyLikedPhotos(deviceId).catchError(
              (_) => <String>{},
            )
          : Future<Object?>.value(<String>{}),
      // L'état du match — c'est lui qui décide Matcher / Accepter / Matché.
      viewer && canQuery
          ? FriendshipApi.matchStateWith(meId: deviceId, peerId: targetId)
          : Future<Object?>.value(),
    ]);

    if (!mounted) return;
    final local = results[0] as ProfileSnapshot?;
    final remote = results[1] as RemoteProfile?;
    final likesByPhoto = results[2] as Map<String, int>;
    final blocked = results[3] as bool;
    final blockerIds = results[4] as Set<String>;
    final likedPhotoUrls = results[5] as Set<String>;
    final rel = results[6] as ({bool matched, bool iLiked, bool peerLikedMe})?;

    setState(() {
      _deviceId = deviceId;
      _local = local;
      _remote = remote;
      _likesByPhoto = likesByPhoto;
      _peerBlocked = blocked;
      _peerBlockedMe = blockerIds.contains(targetId);
      _likedPhotoUrls = likedPhotoUrls;
      _matched = rel?.matched ?? false;
      _iLiked = rel?.iLiked ?? false;
      _peerLikedMe = rel?.peerLikedMe ?? false;
      _loading = false;
    });
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

  Future<void> _unmatchPeer() async {
    if (_targetId.isEmpty || _deviceId.isEmpty || !_matched) return;
    final name = _displayName.isEmpty
        ? AppStrings.t('incoming_someone')
        : _displayName;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('unmatch_q', args: {'name': name}),
      body: AppStrings.t('unmatch_body', args: {'name': name}),
      confirmLabel: AppStrings.t('unmatch'),
    );
    if (ok != true) return;
    try {
      await FriendshipApi.unmatchWith(meId: _deviceId, peerId: _targetId);
      final ids = [_deviceId, _targetId]..sort();
      await ChatUnread.markConversationCleared('dm-${ids[0]}-${ids[1]}');
      if (!mounted) return;
      setState(() {
        _matched = false;
        _iLiked = false;
        _peerLikedMe = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('unmatch'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
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

  /// "Matcher" — I like the peer. If they had already liked me the two likes
  /// meet on the spot and it's a match (celebration overlay); otherwise the
  /// like lands as a pending request they'll answer from Demandes. Optimistic:
  /// flip the button first, roll back if the write fails.
  Future<void> _likePeer() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    setState(() => _iLiked = true);
    try {
      final res = await FriendshipApi.like(meId: _deviceId, peerId: _targetId);
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'profile', 'kind': res.matched ? 'match' : 'like'},
      );
      if (!mounted) return;
      if (res.matched) {
        setState(() {
          _matched = true;
          _iLiked = false;
          _peerLikedMe = false;
        });
        await _celebrateMatch();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _iLiked = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  /// "Accepter" — the peer liked me first, so saying yes IS the match.
  Future<void> _acceptPeer() async {
    if (_targetId.isEmpty || _deviceId.isEmpty) return;
    setState(() {
      _matched = true;
      _peerLikedMe = false;
    });
    try {
      final pending = await FriendshipApi.incomingPendingFrom(
        meId: _deviceId,
        peerId: _targetId,
      );
      if (pending == null) {
        // Their like vanished (unmatched / rejected between two reads) —
        // fall back to liking them, which re-opens a pending request.
        await FriendshipApi.like(meId: _deviceId, peerId: _targetId);
      } else {
        await FriendshipApi.accept(pending.id);
      }
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'profile', 'kind': 'match'},
      );
      if (!mounted) return;
      await _celebrateMatch();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _matched = false;
        _peerLikedMe = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  /// The "It's a match!" celebration. Needs MY profile too — in viewer mode
  /// `_remote` holds the PEER, so pull mine for the card.
  Future<void> _celebrateMatch() async {
    MatchCelebration.markShown(_targetId);
    final me = isSupabaseReady ? await ProfileApi.fetchById(_deviceId) : null;
    final peer = _remote;
    if (!mounted || peer == null) return;
    final meProfile = me ??
        RemoteProfile(
          id: _deviceId,
          handle: '',
          displayName: '',
          language: AppStrings.currentBcp47.value,
          avatarColor: '',
          avatarUrl: '',
        );
    await showMatchOverlay(
      context,
      me: meProfile,
      peer: peer,
      onSayHi: _openChatWithPeer,
    );
    if (mounted) await _reload(silent: true);
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

  /// Bouton œil : ouvre MA CARTE Discover telle que les autres la voient —
  /// mes photos, mon nom, et le panneau d'infos (bio / âge / intérêts) tel
  /// qu'il se déplie chez eux. Pas la page profil : c'est la carte qui décide
  /// si on te like.
  Future<void> _openSelfPreview() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const MyCardPreviewScreen()),
    );
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

  /// Persist one of the "Mes infos" facts (age, height, job, sign, looking
  /// for). Empty clears the column. Optimistic — the panel on Discover reads
  /// the same row.
  Future<void> _savePersonalInfo({
    Object? age = _keep,
    Object? heightCm = _keep,
    Object? job = _keep,
    Object? zodiac = _keep,
    Object? lookingFor = _keep,
  }) async {
    if (_deviceId.isEmpty) return;
    await ProfileApi.updatePersonalInfo(
      userId: _deviceId,
      age: identical(age, _keep) ? ProfileApi.unset : age,
      heightCm: identical(heightCm, _keep) ? ProfileApi.unset : heightCm,
      job: identical(job, _keep) ? ProfileApi.unset : job,
      zodiac: identical(zodiac, _keep) ? ProfileApi.unset : zodiac,
      lookingFor:
          identical(lookingFor, _keep) ? ProfileApi.unset : lookingFor,
    );
    if (mounted) await _reload(silent: true);
  }

  static const Object _keep = Object();

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
      backgroundColor: SC.bg,
      // No header bar. When viewing someone else, the back button + ⋮ menu
      // float directly over the content (added to the Stack below) so the
      // whole profile reads as one continuous page. The "my profile" tab is
      // mounted in IndexedStack, so it never needed a back affordance.
      body: ColoredBox(
        color: SC.bg,
        child: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: RefreshIndicator(
                color: SC.accent,
                backgroundColor: SC.menu,
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
                            likesByPhoto: _likesByPhoto,
                            viewerMode: _isViewingOther,
                            matched: _matched,
                            iLiked: _iLiked,
                            peerLikedMe: _peerLikedMe,
                            peerBlocked: _peerBlocked,
                            peerBlockedMe: _peerBlockedMe,
                            likedPhotoUrls: _likedPhotoUrls,
                            onEditName: _saveName,
                            onEditBio: _saveBio,
                            onEditInterests: _saveInterests,
                            personalInfo: _remote,
                            onSavePersonalInfo: _savePersonalInfo,
                            onTapLikes: _openLikesReceived,
                            onPickPhoto: _pickAndAddPhoto,
                            onPickAvatar: _pickAndSetAvatar,
                            onRemovePhoto: _removePhoto,
                            onEdit: _openEditor,
                            onSettings: _openSettings,
                            onPreview: _openSelfPreview,
                            preview: widget.preview,
                            onLikePeer: _likePeer,
                            onAcceptPeer: _acceptPeer,
                            onToggleBlock: _toggleBlock,
                            onTogglePhotoLike: _togglePhotoLike,
                            onMessagePeer: _openChatWithPeer,
                          ),
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
                    // Un peu d'air : le retour ne colle plus au bord (sans
                    // pour autant le pousser vers le centre).
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        GlassIconButton(
                          icon: Icons.arrow_back_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        const Spacer(),
                        // En aperçu de mon propre profil : pas de menu ⋮
                        // (rien à signaler / bloquer sur soi-même).
                        if (!widget.preview)
                        PopupMenuButton<String>(
                          tooltip: AppStrings.t('tooltip_more'),
                          icon: const Icon(
                            Icons.more_vert,
                            color: SC.textPrimary,
                          ),
                          color: SC.menu,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: const BorderSide(color: SC.glassBorder),
                          ),
                          onSelected: (v) {
                            if (v == 'unmatch') _unmatchPeer();
                            if (v == 'report') _reportPeer();
                            if (v == 'block') _toggleBlock();
                          },
                          itemBuilder: (ctx) => [
                            if (_matched)
                              PopupMenuItem<String>(
                                value: 'unmatch',
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.heart_broken_outlined,
                                      size: 18,
                                      color: SC.textPrimary,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      AppStrings.t('unmatch'),
                                      style: const TextStyle(
                                        color: SC.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
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
    required this.likesByPhoto,
    required this.onEditName,
    required this.onEditBio,
    this.onPickAvatar,
    this.onEditInterests,
    this.personalInfo,
    this.onSavePersonalInfo,
    required this.onTapLikes,
    required this.onPickPhoto,
    required this.onRemovePhoto,
    required this.onEdit,
    required this.onSettings,
    this.onPreview,
    this.preview = false,
    this.viewerMode = false,
    this.matched = false,
    this.iLiked = false,
    this.peerLikedMe = false,
    this.peerBlocked = false,
    this.peerBlockedMe = false,
    this.onLikePeer,
    this.onAcceptPeer,
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

  /// Likes received per photo URL. Only shown on my own profile (private).
  final Map<String, int> likesByPhoto;

  /// Persist the edited display name (own profile, inline).
  final Future<void> Function(String) onEditName;
  final Future<void> Function(String) onEditBio;

  /// Persist the edited interests list. Null in viewer mode (read-only).
  final Future<void> Function(List<String>)? onEditInterests;

  /// The profile row behind the "Mes infos" section (age, height, job, star
  /// sign, looking for) — the same facts the Discover card's panel shows.
  final RemoteProfile? personalInfo;
  final Future<void> Function({
    Object? age,
    Object? heightCm,
    Object? job,
    Object? zodiac,
    Object? lookingFor,
  })? onSavePersonalInfo;
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

  /// Own profile: ouvre l'aperçu "vu de l'extérieur" (bouton œil).
  final VoidCallback? onPreview;

  /// True quand CETTE instance EST l'aperçu (rendu viewer sur mes données) :
  /// masque toutes les actions relationnelles.
  final bool preview;

  /// True when this section is rendering someone else's profile read-only.
  /// Hides editing affordances and swaps Edit/Paramètres for Message /
  /// Follow-back.
  final bool viewerMode;

  /// Viewer-mode only: we liked each other — it's a match.
  final bool matched;

  /// Viewer-mode only: my like is still waiting for their answer.
  final bool iLiked;

  /// Viewer-mode only: they liked me — one tap on "Accepter" makes it a match.
  final bool peerLikedMe;

  /// Viewer-mode only: have I blocked the displayed peer? When true the
  /// action stack collapses to a single "Débloquer" button — the follow
  /// relation and Message CTA are meaningless on a profile I've cut off.
  final bool peerBlocked;

  /// Viewer-mode only: has the displayed peer blocked ME? When true the match
  /// actions are hidden — the edge is dead on their side, so offering to
  /// manage it is misleading.
  final bool peerBlockedMe;

  /// Viewer-mode only: like the peer ("Matcher").
  final VoidCallback? onLikePeer;

  /// Viewer-mode only: accept the like they already sent me ("Accepter").
  final VoidCallback? onAcceptPeer;

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
            // Œil = aperçu de mon profil vu de l'extérieur. Couleur cyan
            // (inversée avec l'engrenage, qui est passé en verre gris).
            Material(
              color: SC.accent.withValues(alpha: 0.15),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPreview ?? () {},
                child: Tooltip(
                  message: AppStrings.t('profile_preview'),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: SC.accent.withValues(alpha: 0.6)),
                    ),
                    child: const Icon(
                      Icons.visibility_outlined,
                      size: 21,
                      color: SC.accent,
                    ),
                  ),
                ),
              ),
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
            // 76 = le bouton (44) + sa marge droite (32) : le prénom reste
            // centré malgré le bouton d'un seul côté.
            const SizedBox(width: 76),
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
            // Paramètres (à la place du crayon), en verre gris — couleur
            // inversée avec l'œil. L'édition du nom / de la bio se fait en
            // tapant le texte directement.
            Material(
              color: Colors.white.withValues(alpha: 0.10),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onSettings,
                child: Tooltip(
                  message: AppStrings.t('settings_title'),
                  child: Container(
                    // Même gabarit que l'œil : 44 de côté, icône 21.
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    child: const Icon(
                      Icons.settings_outlined,
                      size: 21,
                      color: SC.textPrimary,
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
        const SizedBox(height: 24),
        // Photos EN HAUT : "Tes photos (n)" + galerie horizontale.
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
        // ⓘ hint — juste sous le cadre photo. Taps jump to Settings where
        // "Me cacher de mon pays" lives.
        _DiscoverVisibilityHint(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
        const SizedBox(height: 24),
        // "Mes infos" : un seul panneau qui porte la bio (en haut), les faits
        // perso, puis les centres d'intérêt (en bas).
        _ProfileSectionHeader(AppStrings.t('info_section_title')),
        const SizedBox(height: 12),
        _PersonalInfoSection(
          profile: personalInfo,
          onSave: onSavePersonalInfo,
          // Bio en haut du panneau — édition en place, placeholder si vide.
          top: _InlineEditable(
            value: bio,
            placeholder: _bioPlaceholder,
            onSave: onEditBio,
            maxLength: profileBioMaxLength,
            maxLines: 3,
            style: const TextStyle(
              color: SC.textPrimary,
              fontSize: 15.5,
              height: 1.4,
            ),
          ),
          // Centres d'intérêt à l'intérieur du panneau (choix unique).
          bottom: _InterestsSection(
            interests: interests,
            onSave: onEditInterests,
            country: country,
            compact: true,
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
        // Translated into the viewer's UI language when it differs from the
        // peer's spoken language.
        if (!emptyBio) ...[
          const SizedBox(height: 14),
          TranslatedProfileText(
            text: bio,
            profileId: personalInfo?.id ?? handle,
            field: 'bio',
            fromLang: personalInfo?.language ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: SC.textPrimary,
              fontSize: 16.5,
              height: 1.4,
            ),
          ),
        ],
        // Action stack. When I've blocked this peer the whole stack
        // collapses to a single "Débloquer" CTA — the match actions and the
        // Message button would read as wrong on a profile I've cut off.
        // Otherwise: Message + one match action, by relation:
        //  • we matched → "Matché" (inert badge).
        //  • they liked me first → "Accepter" (one tap = match).
        //  • I liked them, no answer yet → "Envoyé".
        //  • nobody liked anybody → "Matcher" (sends the like).
        // En aperçu de mon propre profil : aucune action (on ne se matche /
        // bloque pas soi-même).
        if (!preview) ...[
        const SizedBox(height: 16),
        if (peerBlocked) ...[
          _GradientActionButton(
            label: AppStrings.t('unblock'),
            icon: Icons.lock_open,
            onTap: onToggleBlock ?? () {},
          ),
        ] else ...[
          // Message (et donc l'appel, qui vit dans la conversation) n'existe
          // qu'entre matchs : avant, on ne peut que liker / accepter.
          if (matched) ...[
            _GradientActionButton(
              label: AppStrings.t('profile_message'),
              icon: Icons.chat_bubble_outline,
              onTap: onMessagePeer ?? () {},
              glass: true,
            ),
            if (!peerBlockedMe) const SizedBox(height: 10),
          ],
          // The peer blocked me → their edge with me is dead on their side,
          // so hide the match actions.
          if (!peerBlockedMe) ...[
            if (matched) ...[
              _GradientActionButton(
                label: AppStrings.t('match_matched'),
                icon: Icons.favorite,
                onTap: () {},
                subdued: true,
              ),
            ] else if (peerLikedMe) ...[
              const SizedBox(height: 10),
              _GradientActionButton(
                label: AppStrings.t('match_cta'),
                icon: Icons.favorite,
                onTap: onAcceptPeer ?? () {},
              ),
            ] else if (iLiked) ...[
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
                label: AppStrings.t('match_cta'),
                icon: Icons.favorite_border,
                onTap: onLikePeer ?? () {},
              ),
            ],
          ],
        ],
        ],
        // Centres d'intérêt (read-only) — just above the photos.
        if (interests.isNotEmpty) ...[
          const SizedBox(height: 24),
          _ProfileSectionHeader(AppStrings.t('profile_interests_section')),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final tag in interests)
                InterestTagChip(
                  label: tag,
                  color: interestColor(tag),
                ),
            ],
          ),
        ],
        // Grille photos (+ tuile infos perso, même format).
        const SizedBox(height: 24),
        _PeerMediaStack(
          personalInfo: personalInfo,
          photos: photos,
          likedPhotoUrls: likedPhotoUrls,
          onTogglePhotoLike: onTogglePhotoLike,
        ),
      ],
    );
  }
}

/// Read-only "infos perso" as a portrait TILE — same footprint as a photo
/// cell in [_PeerMediaStack]. Only emoji + value (no "Âge" / "Métier" labels).
class _PeerInfoCard extends StatelessWidget {
  const _PeerInfoCard({required this.profile});
  final RemoteProfile? profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    if (p == null) return const SizedBox.shrink();
    final rows = <({String emoji, String value})>[
      if (p.age != null) (emoji: kFactEmojiAge, value: '${p.age}'),
      if (p.job.trim().isNotEmpty)
        (emoji: kFactEmojiJob, value: displayJob(p.job)),
      if (p.zodiac.trim().isNotEmpty)
        (emoji: kFactEmojiZodiac, value: displayZodiac(p.zodiac)),
      if (p.lookingFor.trim().isNotEmpty)
        (emoji: kFactEmojiLookingFor, value: displayLookingFor(p.lookingFor)),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Material(
      color: SC.bubbleIn,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: SC.glassBorder),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) const SizedBox(height: 10),
              Row(
                children: [
                  Text(r.emoji, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SC.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Grille Instagram sur le profil d'un pair : tuile infos perso (même format
/// que les photos) en première position, puis chaque photo en portrait.
class _PeerMediaStack extends StatelessWidget {
  const _PeerMediaStack({
    required this.personalInfo,
    required this.photos,
    required this.likedPhotoUrls,
    required this.onTogglePhotoLike,
  });

  final RemoteProfile? personalInfo;
  final List<String> photos;
  final Set<String> likedPhotoUrls;
  final void Function(String photoUrl)? onTogglePhotoLike;

  static bool _hasInfo(RemoteProfile? p) =>
      p != null &&
      (p.age != null ||
          p.job.trim().isNotEmpty ||
          p.zodiac.trim().isNotEmpty ||
          p.lookingFor.trim().isNotEmpty);

  // Grille façon Instagram : 3 par ligne, tuiles portrait (3:4).
  static const double _aspect = 216 / 162; // height / width
  static const double _spacing = 8;
  static const int _columns = 3;

  @override
  Widget build(BuildContext context) {
    final hasInfo = _hasInfo(personalInfo);
    if (!hasInfo && photos.isEmpty) return const _EmptyPhotosPlaceholder();

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth =
            (constraints.maxWidth - _spacing * (_columns - 1)) / _columns;
        final tileHeight = tileWidth * _aspect;
        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          children: [
            if (hasInfo)
              SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _PeerInfoCard(profile: personalInfo),
              ),
            for (var i = 0; i < photos.length; i++)
              SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _PhotoCell(
                  photoUrl: photos[i],
                  viewerMode: true,
                  onTap: () => showPhotoViewer(
                    context,
                    photos: photos,
                    index: i,
                    viewerMode: true,
                  ),
                  iLikePeer: likedPhotoUrls.contains(photos[i]),
                  onTogglePeerLike: onTogglePhotoLike != null
                      ? () => onTogglePhotoLike!(photos[i])
                      : null,
                ),
              ),
          ],
        );
      },
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
    this.discoverPhotoUrl = '',
    this.onSelectDiscover,
  });

  final List<String> photos;

  /// Toujours false désormais — le profil d'un pair passe par [_PeerMediaStack].
  /// Le param reste pour ne pas casser les points d'appel.
  final bool viewerMode;
  final VoidCallback onPick;
  final void Function(String url) onRemove;
  // Own profile: URL of the Discover photo (cyan ring) + select-by-tap.
  final String discoverPhotoUrl;
  final void Function(String url)? onSelectDiscover;
  // Own profile: likes received per photo URL.
  final Map<String, int> likesByPhoto;
  final VoidCallback? onTapLikes;

  // Portrait tiles (3:4) — a single horizontal, scrollable row of larger tiles.
  static const double _aspect = 216 / 162; // height / width
  static const double _spacing = 8;

  @override
  Widget build(BuildContext context) {
    final canAdd = photos.length < profilePhotosMax;
    // "Tes photos" agrandies : une rangée horizontale de grandes tuiles (la
    // tuile "+" d'abord), qu'on fait défiler.
    const double tileWidth = 210;
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
}

/// Inline, in-place text editor — no bottom sheet. Shows [value] (or the
/// [placeholder] when empty) as centred tappable text; tapping turns it into
/// a centred field that commits on submit (keyboard "done") or when focus
/// leaves. Reused for the name and the bio on my own profile.
/// Les 5 faits optionnels du profil, éditables en place. Une ligne vide se lit
/// "Ajouter" : rien n'est obligatoire, et un champ vidé disparaît du panneau
/// que la carte Discover déplie.
class _PersonalInfoSection extends StatelessWidget {
  const _PersonalInfoSection({
    required this.profile,
    required this.onSave,
    this.top,
    this.bottom,
  });

  final RemoteProfile? profile;
  final Future<void> Function({
    Object? age,
    Object? heightCm,
    Object? job,
    Object? zodiac,
    Object? lookingFor,
  })? onSave;

  /// Rendu EN HAUT du panneau, au-dessus des lignes d'infos (la bio).
  final Widget? top;

  /// Rendu EN BAS du panneau, sous les lignes d'infos (les centres d'intérêt).
  final Widget? bottom;

  static Widget get _divider => Divider(
        height: 1,
        thickness: 1,
        color: Colors.white.withValues(alpha: 0.06),
      );

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final save = onSave;
    if (save == null) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: SC.glassStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SC.glassBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          if (top != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: top!,
            ),
            _divider,
          ],
          // Âge : roulette 15–40, plus de saisie libre.
          _PersonalInfoRow(
            emoji: kFactEmojiAge,
            label: AppStrings.t('info_age'),
            value: p?.age?.toString() ?? '',
            onPick: (ctx) async {
              final picked = await showWheelPicker(
                context: ctx,
                title: AppStrings.t('info_age'),
                emoji: kFactEmojiAge,
                labels: [for (final a in kAgeOptions) '$a'],
                initialIndex: ageIndex(p?.age),
                allowClear: p?.age != null,
              );
              if (picked == null) return;
              if (picked < 0) {
                await save(age: null);
                return;
              }
              await save(age: kAgeOptions[picked]);
            },
          ),
          // Métier / signe / looking-for : plus de champ libre. Une roulette
          // écrit une clé FR stable ; l'affichage la localise pour le viewer.
          _PersonalInfoRow(
            emoji: kFactEmojiJob,
            label: AppStrings.t('info_job'),
            value: displayJob(p?.job ?? ''),
            onPick: (ctx) async {
              final current = normalizeJob(p?.job ?? '');
              final picked = await showWheelPicker(
                context: ctx,
                title: AppStrings.t('info_job'),
                emoji: kFactEmojiJob,
                labels: [for (final k in kJobSectors) jobSectorLabel(k)],
                initialIndex: jobSectorIndex(current),
                allowClear: current.isNotEmpty,
              );
              if (picked == null) return;
              if (picked < 0) {
                await save(job: '');
                return;
              }
              await save(job: kJobSectors[picked]);
            },
          ),
          _PersonalInfoRow(
            emoji: kFactEmojiZodiac,
            label: AppStrings.t('info_zodiac'),
            value: displayZodiac(p?.zodiac ?? ''),
            onPick: (ctx) async {
              final current = normalizeZodiac(p?.zodiac ?? '');
              final picked = await showWheelPicker(
                context: ctx,
                title: AppStrings.t('info_zodiac'),
                emoji: kFactEmojiZodiac,
                labels: [
                  // Months only in the wheel — cards show the sign alone.
                  for (final k in kZodiacSigns) displayZodiacWithMonths(k),
                ],
                initialIndex: zodiacIndex(current),
                allowClear: current.isNotEmpty,
              );
              if (picked == null) return;
              if (picked < 0) {
                await save(zodiac: '');
                return;
              }
              await save(zodiac: kZodiacSigns[picked]);
            },
          ),
          _PersonalInfoRow(
            emoji: kFactEmojiLookingFor,
            label: AppStrings.t('info_looking_for'),
            value: displayLookingFor(p?.lookingFor ?? ''),
            onPick: (ctx) async {
              final current = normalizeLookingFor(p?.lookingFor ?? '');
              final picked = await showWheelPicker(
                context: ctx,
                title: AppStrings.t('info_looking_for'),
                emoji: kFactEmojiLookingFor,
                labels: [
                  for (final k in kLookingForOptions) lookingForLabel(k),
                ],
                initialIndex: lookingForIndex(current),
                allowClear: current.isNotEmpty,
              );
              if (picked == null) return;
              if (picked < 0) {
                await save(lookingFor: '');
                return;
              }
              await save(lookingFor: kLookingForOptions[picked]);
            },
            last: bottom == null,
          ),
          if (bottom != null) ...[
            _divider,
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: bottom!,
            ),
          ],
        ],
      ),
    );
  }
}

class _PersonalInfoRow extends StatelessWidget {
  const _PersonalInfoRow({
    required this.emoji,
    required this.label,
    required this.value,
    this.onSave,
    this.onPick,
    this.numeric = false,
    this.last = false,
  }) : assert(onSave != null || onPick != null);

  final String emoji;
  final String label;
  final String value;
  final bool numeric;
  final bool last;

  /// Champ libre : la valeur s'édite en place.
  final Future<void> Function(String)? onSave;

  /// Valeur à format imposé : un tap ouvre un sélecteur, il n'y a rien à
  /// taper. [onSave] est alors inutile.
  final Future<void> Function(BuildContext)? onPick;

  @override
  Widget build(BuildContext context) {
    final pick = onPick;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 17)),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(color: SC.textMuted, fontSize: 14),
              ),
              const Spacer(),
              Flexible(
                child: pick != null
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => pick(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            value.isEmpty ? AppStrings.t('info_add') : value,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: value.isEmpty
                                  ? SC.textMuted
                                  : SC.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              fontStyle: value.isEmpty
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                          ),
                        ),
                      )
                    : _InlineEditable(
                        value: value,
                        placeholder: AppStrings.t('info_add'),
                        onSave: onSave!,
                        maxLength: 60,
                        keyboardType: numeric ? TextInputType.number : null,
                        style: const TextStyle(
                          color: SC.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
        if (!last)
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.06),
          ),
      ],
    );
  }
}

class _InlineEditable extends StatefulWidget {
  const _InlineEditable({
    required this.value,
    required this.placeholder,
    required this.onSave,
    required this.maxLength,
    required this.style,
    this.maxLines = 1,
    this.keyboardType,
  });
  final String value;
  final String placeholder;
  final Future<void> Function(String) onSave;
  final int maxLength;

  /// Number pad for the numeric facts (age, height); null = plain text.
  final TextInputType? keyboardType;

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
      keyboardType: widget.keyboardType,
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
    this.compact = false,
  });

  final List<String> interests;
  final Future<void> Function(List<String>)? onSave;

  /// The user's country — selects which interests taxonomy the picker shows.
  final String country;

  /// Rendu dans le panneau "Mes infos" : un petit libellé muet façon ligne
  /// d'info au lieu du gros titre de section (et pas de badge +20).
  final bool compact;

  @override
  State<_InterestsSection> createState() => _InterestsSectionState();
}

class _InterestsSectionState extends State<_InterestsSection> {
  late Set<String> _sel = {...widget.interests};

  /// Vrai pendant que la feuille est ouverte : la sélection en cours est celle
  /// de l'utilisateur, on ne la réaligne pas sur le parent tant qu'il choisit.
  bool _picking = false;

  @override
  void didUpdateWidget(covariant _InterestsSection old) {
    super.didUpdateWidget(old);
    // Resync with the parent's saved list while closed (e.g. after a save
    // round-trip). While the sheet is open we keep the in-progress selection.
    if (!_picking && !_sameSet(_sel, widget.interests)) {
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
        _sel = {..._sel}..remove(tag);
      } else if (_sel.length < profileInterestsMax) {
        _sel = {..._sel, tag};
      }
    });
    widget.onSave?.call(_sel.toList());
  }

  /// Le sélecteur s'ouvre PAR-DESSUS la page, dans une feuille modale. En
  /// ligne, il poussait tout le contenu vers le bas et débordait sous la barre
  /// de navigation.
  Future<void> _openPicker() async {
    setState(() => _picking = true);
    // Une POP-UP, pas une feuille : la feuille modale montait du bas et prenait
    // toute la hauteur de l'écran, contenu collé en haut et grand vide noir en
    // dessous. Un dialogue se pose au centre et fait exactement la taille du
    // panneau, qui est fixe (une page de catégorie + les points + le bouton).
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        // Le dialogue a son propre cycle de rendu : sans ce setState local, les
        // chips cochés ne changeraient d'état qu'à la fermeture.
        builder: (dialogCtx, setSheetState) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16),
          child: _InlineInterestPicker(
            sel: _sel,
            onToggle: (tag) {
              _toggle(tag);
              setSheetState(() {});
            },
            onDone: () => Navigator.of(dialogCtx).pop(),
            country: widget.country,
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _picking = false);
    final save = widget.onSave;
    if (save != null) await save(_sel.toList());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.compact)
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 2),
            child: Row(
              children: [
                const Text(kFactEmojiInterests, style: TextStyle(fontSize: 17)),
                const SizedBox(width: 12),
                Text(
                  AppStrings.t('profile_interests_section'),
                  style: const TextStyle(color: SC.textMuted, fontSize: 14),
                ),
              ],
            ),
          )
        else ...[
          _ProfileSectionHeader(
            AppStrings.t('profile_interests_section'),
            trailing: const _RewardHint(),
          ),
          const SizedBox(height: 12),
        ],
        // Les chips choisis + le chip "Ajouter". N'importe lequel ouvre la
        // feuille de sélection, qui se pose PAR-DESSUS la page.
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final tag in _sel)
              InterestTagChip(
                label: tag,
                color: interestColor(tag),
                onTap: _openPicker,
              ),
            if (_sel.length < profileInterestsMax)
              _InterestAddChip(onTap: _openPicker),
          ],
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
    final canPrev = _page > 0;
    final canNext = _page < cats.length - 1;
    return Container(
      // Plus de marge haute : elle datait du temps où ce panneau se dépliait
      // sous les chips. Dans une pop-up centrée, elle décentrait le contenu.
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      decoration: BoxDecoration(
        color: SC.bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SC.glassBorderStrong),
      ),
      child: Column(
        // SANS ça, la colonne prend toute la hauteur qu'on lui offre : dans un
        // dialogue, elle s'étirait jusqu'en bas de l'écran et le panneau
        // devenait un grand rectangle noir. Elle fait sa taille, désormais.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Croix de fermeture — même teinte que l'icône paramètres.
          Align(
            alignment: Alignment.centerLeft,
            child: Material(
              color: Colors.white.withValues(alpha: 0.10),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onDone,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.22),
                    ),
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: SC.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Flèches gauche / droite autour du carrousel de catégories.
          SizedBox(
            height: 248,
            child: Row(
              children: [
                _PickerNavArrow(
                  icon: Icons.chevron_left_rounded,
                  enabled: canPrev,
                  onTap: canPrev ? () => _goTo(_page - 1) : null,
                ),
                Expanded(
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
                _PickerNavArrow(
                  icon: Icons.chevron_right_rounded,
                  enabled: canNext,
                  onTap: canNext ? () => _goTo(_page + 1) : null,
                ),
              ],
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

/// Chevron de navigation du carrousel d'intérêts — même teinte que
/// l'icône paramètres du profil ([SC.textPrimary]).
class _PickerNavArrow extends StatelessWidget {
  const _PickerNavArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 48,
          child: Icon(
            icon,
            size: 28,
            color: enabled
                ? SC.textPrimary
                : SC.textPrimary.withValues(alpha: 0.28),
          ),
        ),
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
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final opt in cat.options)
                    InterestTagChip(
                      label: opt,
                      // Une seule couleur par catégorie (celle du header).
                      color: cat.color,
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
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline, size: 14, color: SC.textMuted),
              ),
              const SizedBox(width: 6),
              Flexible(
                // Keywords wrapped in **…** in app_strings render cyan.
                child: Text.rich(
                  _highlightKeywords(AppStrings.t('discover_visibility_hint')),
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
