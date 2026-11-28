import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../widgets/sparkles.dart';
import '../widgets/failure_sheet.dart';
import '../widgets/tap_pad.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../services/analytics.dart';

import '../services/app_strings.dart';
import '../services/profile_views_api.dart';
import '../widgets/profile_views_card.dart';
import 'profile_views_screen.dart';
import '../widgets/my_bio_card.dart';
import '../widgets/voice_intro_player.dart';
import '../services/saved_profiles_api.dart';
import '../widgets/peer_profile_view.dart';
import '../widgets/round_flag.dart';
import '../services/notif_enable_flow.dart';
import '../services/swayco_sounds.dart';
import '../services/block_api.dart';
import '../services/chat_unread.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/age_range.dart';
import '../services/fact_emojis.dart';
import '../services/interests.dart';
import '../services/job_sectors.dart';
import '../services/languages.dart';
import '../services/match_celebration.dart';
import '../services/nav_chrome.dart';
import '../services/nav_tab.dart';
import '../services/persona_categories.dart';
import '../services/profile_api.dart';
import '../services/presence_service.dart';
import '../services/revenue_cat.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../services/zodiac.dart';
import '../theme/swayco_theme.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/nav_auto_hide.dart';
import '../widgets/fade_scale_route.dart';
import '../widgets/info_bento.dart';
import '../widgets/profile_info_card.dart';
import '../widgets/settings_hero.dart';
import '../widgets/interest_chip.dart';
import '../widgets/location_picker_sheet.dart';
import '../widgets/popup_kit.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/report_dialog.dart';
import '../widgets/swayco_animations.dart';
import '../widgets/swayco_dialog.dart';
import '../widgets/swayco_popups_extra.dart';
import '../widgets/wheel_picker_sheet.dart';
import '../widgets/pro_banner.dart';
import 'chat_thread_screen.dart';
import 'photo_crop_screen.dart';
// L'aperÃ§u "ma carte" vit dans le Discover : il rÃ©utilise le widget de carte
// du feed pour que l'aperÃ§u soit le rendu rÃ©el, pas une copie qui dÃ©rive.
import 'discover_screen.dart'
    show ProfileInfoPanel, discoverCardAspect;
import '../widgets/passport_tile.dart';
import 'settings_screen.dart';
import '../services/friendly_error.dart';

/// Profile view. Two modes:
///
///   * `userId` is null (default): "my own" profile â editable, shows the
///     Free Account / Premium card, Edit + ParamÃ¨tres buttons.
///   * `userId` is set: another user's profile, viewed read-only. Camera /
///     edit affordances are hidden, premium card and the call-language
///     warning are dropped (private to me), and the action row becomes
///     Bloquer / DÃ©bloquer instead of Edit / ParamÃ¨tres.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.userId, this.preview = false});

  /// When non-null, render the profile of the given Supabase auth user id
  /// in read-only "viewer" mode rather than my own profile.
  final String? userId;

  /// AperÃ§u de MON profil tel que les autres le voient : rendu viewer sur mes
  /// propres donnÃ©es, mais sans les actions (Message / Matcher / bloquer) ni le
  /// menu â® â juste un bouton retour pour fermer.
  final bool preview;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver {
  String _deviceId = '';
  RemoteProfile? _remote;
  ProfileSnapshot? _local;
  bool _loading = true;
  // Viewer-mode only: am I currently blocking the displayed user?
  bool _peerBlocked = false;
  // Viewer-mode only: has the displayed user blocked ME? Hides the
  // relationship actions (their edge with me is dead on their side).
  bool _peerBlockedMe = false;
  // Viewer-mode only: where the two of us stand.
  //   `_matched`     â we liked each other: it's a match.
  //   `_iLiked`      â my like is waiting for their answer.
  //   `_peerLikedMe` â their like is waiting for mine (one tap = match).
  bool _matched = false;
  bool _iLiked = false;
  bool _peerLikedMe = false;
  Timer? _pollTimer;

  bool get _isViewingOther => widget.userId != null || widget.preview;
  String get _targetId => widget.userId ?? _deviceId;

  /// Ce profil est-il dans mes enregistrés ? (profil d'un pair)
  bool _peerSaved = false;
  bool _savingPeer = false;

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
    if (!_isViewingOther) {
      NavTab.addPhotoTick.addListener(_onAddPhotoRequest);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onAddPhotoRequest());
    }
  }

  void _onAddPhotoRequest() {
    if (!mounted || _isViewingOther) return;
    if (!NavTab.takeAddPhotoRequest()) return;
    // After the tab jump, wait one frame so this sheet isn't racing the
    // closing onboarding dialog (which used to lose to "Ta photo, c'est ici").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_pickAndAddPhoto());
    });
  }

  /// Le défilement de la page d'un pair : la barre du haut (retour, badge, ⋮)
  /// le suit, pour partir avec la couverture au lieu de rester collée aux photos.
  final ScrollController _peerScroll = ScrollController();

  @override
  void dispose() {
    _peerScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    NavTab.addPhotoTick.removeListener(_onAddPhotoRequest);
    _pollTimer?.cancel();
    // Quitter le profil d'un pair avec la barre rangée : elle doit être là pour
    // la page dessous (après l'image, pas pendant que l'arbre se démonte).
    if (widget.userId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => NavChrome.show());
    }
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

    // TOUT EN PARALLÃLE. Ces sept lectures s'attendaient les unes les autres :
    // sept allers-retours rÃ©seau bout Ã  bout, soit plusieurs secondes d'Ã©cran
    // vide sur une connexion mobile ordinaire. Aucune ne dÃ©pend du rÃ©sultat
    // d'une autre â seule l'identitÃ© de l'appareil, obtenue au-dessus, leur est
    // nÃ©cessaire. Elles partent donc ensemble : le temps d'attente devient
    // celui de la plus lente, pas la somme.
    final viewer = _isViewingOther;
    final canQuery = isSupabaseReady && deviceId.isNotEmpty;
    unawaited(_loadSaved());
    // Une vue de profil (une fois à l'ouverture ; pas mon aperçu).
    final seenPeer = widget.userId;
    if (!silent && !widget.preview && seenPeer != null) {
      unawaited(ProfileViewsApi.record(seenPeer));
    }
    final results = await Future.wait<Object?>([
      // Cache local (mon profil seulement) : instantanÃ©, mais il attendait
      // quand mÃªme son tour derriÃ¨re le rÃ©seau.
      viewer ? Future<Object?>.value() : UserPrefs.loadProfile(),
      isSupabaseReady
          ? ProfileApi.fetchById(targetId)
          : Future<Object?>.value(),
      viewer && canQuery
          ? BlockApi.isBlocked(blockerId: deviceId, otherId: targetId)
          : Future<Object?>.value(false),
      // Ce pair m'a-t-il bloquÃ© ? Si oui, les actions de match disparaissent â
      // l'arÃªte est morte de son cÃ´tÃ©.
      viewer && canQuery
          ? BlockApi.fetchMyBlockerIds().catchError(
              (_) => <String>{},
            )
          : Future<Object?>.value(<String>{}),
      // L'Ã©tat du match â c'est lui qui dÃ©cide Matcher / Accepter / MatchÃ©.
      viewer && canQuery
          ? FriendshipApi.matchStateWith(meId: deviceId, peerId: targetId)
          : Future<Object?>.value(),
    ]);

    if (!mounted) return;
    final local = results[0] as ProfileSnapshot?;
    final remote = results[1] as RemoteProfile?;
    final blocked = results[2] as bool;
    final blockerIds = results[3] as Set<String>;
    final rel = results[4] as ({bool matched, bool iLiked, bool peerLikedMe})?;

    // Mon propre profil : son Pro en base compte aussi côté app.
    if (!_isViewingOther && remote != null) {
      RevenueCat.setServerGrantedPro(remote.isPro || remote.isPlus);
    }
    setState(() {
      _deviceId = deviceId;
      _local = local;
      _remote = remote;
      _peerBlocked = blocked;
      _peerBlockedMe = blockerIds.contains(targetId);
      _matched = rel?.matched ?? false;
      _iLiked = rel?.iLiked ?? false;
      _peerLikedMe = rel?.peerLikedMe ?? false;
      _loading = false;
    });
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
      ).showSnackBar(SnackBar(
          content: Text(friendlyError(e))));
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
      HapticFeedback.mediumImpact();
      SwaycoSounds.play(SwSound.block);
      }
      if (!mounted) return;
      setState(() => _peerBlocked = !wasBlocked);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
          content: Text(friendlyError(e))));
    }
  }

  /// "Matcher" â I like the peer. If they had already liked me the two likes
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
      if (!res.matched && res.friendship != null) {
        unawaited(NotifEnableFlow.askAfterFirstLike(context));
      }
      if (res.matched) {
        MatchCelebration.markShown(_targetId);
        setState(() {
          _matched = true;
          _iLiked = false;
          _peerLikedMe = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _iLiked = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
          content: Text(friendlyError(e))));
    }
  }

  /// "Accepter" â the peer liked me first, so saying yes IS the match.
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
        // Their like vanished (unmatched / rejected between two reads) â
        // fall back to liking them, which re-opens a pending request.
        await FriendshipApi.like(meId: _deviceId, peerId: _targetId);
      } else {
        await FriendshipApi.accept(pending.id);
      }
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'profile', 'kind': 'match'},
      );
      MatchCelebration.markShown(_targetId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _matched = false;
        _peerLikedMe = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
          content: Text(friendlyError(e))));
    }
  }

  Future<void> _openChatWithPeer() async {
    VoiceIntroPlayer.stopActive();
    if (_deviceId.isEmpty || _targetId.isEmpty) return;
    final ids = [_deviceId, _targetId]..sort();
    final convId = 'dm-${ids[0]}-${ids[1]}';
    final title = _displayName.isEmpty
        ? AppStrings.t('profile_anonymous')
        : _displayName;
    await Navigator.of(context).push<void>(
      chatThreadRoute(
        builder: (_) => ChatThreadScreen(
          conversationId: convId,
          title: title,
          peerDeviceId: _targetId,
        ),
      ),
    );
  }

  /// Bouton Åil : ouvre MA CARTE Discover telle que les autres la voient â
  /// mes photos, mon nom, et le panneau d'infos (bio / Ã¢ge / intÃ©rÃªts) tel
  /// qu'il se dÃ©plie chez eux. Pas la page profil : c'est la carte qui dÃ©cide
  /// si on te like.
  Future<void> _openSelfPreview() async {
    if (_deviceId.isEmpty) return;
    VoiceIntroPlayer.stopActive();
    await Navigator.of(context).push<void>(
      // Apparaît sur place, comme la pop-up globe.
      fadeScaleRoute<void>(
        (_) => ProfileScreen(userId: _deviceId, preview: true),
      ),
    );
    VoiceIntroPlayer.stopActive();
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

  /// True when viewing a peer who is currently online â `last_seen`
  /// within the last 2 minutes â and who has not hidden their status.
  bool get _peerOnline {
    if (!_isViewingOther) return false;
    final r = _remote;
    // La rÃ¨gle commune : elle ajoute ici la rÃ©ciprocitÃ© qui manquait â masquer
    // son propre statut n'Ã©teignait pas la pastille sur un profil visitÃ©.
    return r != null && isPeerOnline(r);
  }

  /// "Tes photos" â pick an image and append it to the gallery. The first
  /// photo doubles as the PDP (avatar) + Discover photo; [ProfileApi.
  /// addProfilePhoto] keeps those columns in sync.
  Future<void> _pickAndAddPhoto() async {
    if (_deviceId.isEmpty) {
      _deviceId = await DeviceId.getOrCreate();
    }
    if (_deviceId.isEmpty) return;
    if (!isSupabaseReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('backend_unavailable'))));
      return;
    }
    final current = _remote?.photos ?? const <String>[];
    if (current.length >= profilePhotosMax) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('photos_full'))));
      return;
    }
    final XFile? file;
    Uint8List bytes;
    try {
      final picker = ImagePicker();
      file = await picker.pickImage(
        source: ImageSource.gallery,
        // The Discover card is portrait â keep more pixels than the avatar
        // (1024Â² â 1600 max edge) so the photo doesn't look soft full-screen.
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 88,
      );
      if (file == null) return;
      bytes = await file.readAsBytes();
    } catch (e) {
      if (!mounted) return;
      showUploadFailedSheet(context, error: e, onRetry: _pickAndAddPhoto);
      return;
    }
    if (!mounted) return;
    // Let the user reframe / resize before posting (Discover card ratio).
    final cropped = await PhotoCropScreen.pick(
      context,
      bytes: bytes,
      aspect: discoverCardAspect(context),
      maxEdge: 1600,
    );
    if (cropped == null || !mounted) return;
    bytes = cropped;
    // The crop exports JPEG; on its untouched-original fallback keep the PNG tag.
    final ext = (bytes.length > 1 && bytes[0] == 0x89 && bytes[1] == 0x50)
        ? 'png'
        : 'jpg';
    Future<void> attempt() async {
    try {
      await ProfileApi.addProfilePhoto(
        deviceId: _deviceId,
        bytes: bytes,
        current: current,
        contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
        currentDiscover: _remote?.discoverPhotoUrl ?? '',
      );
      HapticFeedback.mediumImpact();
      SwaycoSounds.play(SwSound.photoAdded);
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      showUploadFailedSheet(context, error: e, photoBytes: bytes, onRetry: attempt, onPickOther: _pickAndAddPhoto);
    }
    }
    await attempt();
  }

  /// PDP bubble â pick an image and set it as the (independent) profile
  /// avatar via [ProfileApi.uploadAvatar]. Separate from the gallery: this
  /// only writes `avatar_url`, leaving "Tes photos" untouched.
  Future<void> _pickAndSetAvatar() async {
    if (_deviceId.isEmpty) return;
    if (!isSupabaseReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('backend_unavailable'))));
      return;
    }
    final XFile? file;
    Uint8List bytes;
    try {
      final picker = ImagePicker();
      file = await picker.pickImage(
        source: ImageSource.gallery,
        // The avatar renders small and round â 1024Â² is plenty and keeps the
        // upload light.
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 88,
      );
      if (file == null) return;
      bytes = await file.readAsBytes();
    } catch (e) {
      if (!mounted) return;
      showUploadFailedSheet(context, error: e, onRetry: _pickAndSetAvatar);
      return;
    }
    if (!mounted) return;
    final cropped = await PhotoCropScreen.pick(
      context,
      bytes: bytes,
      aspect: 1,
      maxEdge: 1024,
      circle: true,
    );
    if (cropped == null || !mounted) return;
    bytes = cropped;
    final ext = (bytes.length > 1 && bytes[0] == 0x89 && bytes[1] == 0x50)
        ? 'png'
        : 'jpg';
    Future<void> attempt() async {
    try {
      await ProfileApi.uploadAvatar(
        deviceId: _deviceId,
        bytes: bytes,
        contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
      );
      HapticFeedback.mediumImpact();
      SwaycoSounds.play(SwSound.photoAdded);
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      showUploadFailedSheet(context, error: e, photoBytes: bytes, onRetry: attempt, onPickOther: _pickAndSetAvatar);
    }
    }
    await attempt();
  }

  /// Clear the dedicated PDP (the ✕ on the edit-account sheet's bubble). The
  /// avatar then falls back to the Discover photo / initials. Gallery untouched.
  Future<void> _clearAvatar() async {
    if (_deviceId.isEmpty || !isSupabaseReady) return;
    try {
      await ProfileApi.clearAvatar(_deviceId);
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      showUploadFailedSheet(context, error: e, onRetry: _clearAvatar);
    }
  }

  /// Remove a single gallery photo. Re-syncs the Discover photo server-side;
  /// cascades a like wipe only when the gallery becomes empty (see
  /// [ProfileApi.removeProfilePhoto]).
  Future<void> _removePhoto(String url) async {
    if (_deviceId.isEmpty) return;
    // Supprimer LA dernière, ce n'est pas supprimer une photo : c'est sortir de
    // Discover. Sans photo la carte ne passe plus, donc plus personne ne peut
    // ajouter — ça se dit avant, pas après.
    final isLast = (_remote?.photos.length ?? 0) <= 1;
    final ok = await showSwaycoConfirm(
      context: context,
      title: AppStrings.t('delete_photo_q'),
      body: AppStrings.t(
        isLast ? 'delete_photo_body_last' : 'delete_photo_body',
      ),
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
      HapticFeedback.lightImpact();
      SwaycoSounds.play(SwSound.deleted);
      if (!mounted) return;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
          content: Text(AppStrings.t('delete_failed', args: {'msg': '$e'}))));
    }
  }

  /// Déplacer une photo change son RANG d'apparition : [from] et [to] sont des
  /// positions finales dans la galerie. C'est ce classement qui pilote la carte
  /// Discover, qui les déroule toutes dans l'ordre — il n'y a plus de photo à
  /// désigner, il y a une première.
  ///
  /// Optimiste : la galerie se réordonne sous le doigt, l'écriture rattrape
  /// derrière. Si elle échoue, l'ordre d'avant revient — un classement qui
  /// n'existerait que sur cet écran serait pire que pas de déplacement.
  Future<void> _reorderPhotos(int from, int to) async {
    final prev = _remote;
    if (prev == null || _deviceId.isEmpty) return;
    final photos = [...prev.photos];
    if (from < 0 || from >= photos.length) return;
    final target = to.clamp(0, photos.length - 1);
    if (target == from) return;
    photos.insert(target, photos.removeAt(from));
    setState(
      () => _remote = prev.copyWith(
        photos: photos,
        discoverPhotoUrl: photos.first,
      ),
    );
    try {
      await ProfileApi.reorderProfilePhotos(
        deviceId: _deviceId,
        photos: photos,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _remote = prev); // on remet l'ordre d'avant
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
          content: Text(friendlyError(e))));
    }
  }

  Future<void> _saveName(String name) async {
    if (_deviceId.isEmpty) return;
    final trimmed = name.trim();
    // Ignore an empty name â a profile must keep one.
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
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('save_failed'))));
      return;
    }
    await UserPrefs.setFirstName(saved);
    SwaycoSounds.play(SwSound.profileSaved);
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
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('save_failed'))));
      return;
    }
    SwaycoSounds.play(SwSound.profileSaved);
    if (!mounted || _remote == null) return;
    setState(() => _remote = _remote!.copyWith(bio: saved));
  }

  /// Persist one of the "Mes infos" facts (age, height, job, sign, looking
  /// for). Empty clears the column. Optimistic â the panel on Discover reads
  /// the same row.
  Future<void> _savePersonalInfo({
    Object? age = _keep,
    Object? heightCm = _keep,
    Object? job = _keep,
    Object? zodiac = _keep,
    Object? personaCategory = _keep,
    Object? nationality = _keep,
    Object? originMother = _keep,
    Object? originFather = _keep,
  }) async {
    if (_deviceId.isEmpty) return;
    await ProfileApi.updatePersonalInfo(
      userId: _deviceId,
      age: identical(age, _keep) ? ProfileApi.unset : age,
      heightCm: identical(heightCm, _keep) ? ProfileApi.unset : heightCm,
      job: identical(job, _keep) ? ProfileApi.unset : job,
      zodiac: identical(zodiac, _keep) ? ProfileApi.unset : zodiac,
      personaCategory: identical(personaCategory, _keep)
          ? ProfileApi.unset
          : personaCategory,
      nationality: identical(nationality, _keep) ? ProfileApi.unset : nationality,
      originMother:
          identical(originMother, _keep) ? ProfileApi.unset : originMother,
      originFather:
          identical(originFather, _keep) ? ProfileApi.unset : originFather,
    );
    SwaycoSounds.play(SwSound.profileSaved);
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
      ).showSnackBar(SnackBar(content: Text(AppStrings.t('save_failed'))));
      return;
    }
    SwaycoSounds.play(SwSound.profileSaved);
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
      settingsHeroRoute<void>((_) => const SettingsScreen()),
    );
    // Profile data may have changed (e.g. account deleted â ignored;
    // sign-out â routed away by the auth listener).
    if (mounted) await _reload();
  }

  /// Pencil next to the PDP — bottom sheet (same pattern as the language
  /// wheel), not a full Settings push. First name / city / live translation.
  /// Stays open while a row's editor (dialog / nested sheet / gallery) is up.
  Future<void> _openEditAccountSheet() async {
    if (!mounted) return;
    final callLang = await UserPrefs.loadCallSpokenLang();
    if (!mounted) return;
    var displayName = _remote?.displayName.trim() ?? '';
    var avatarUrl = _remote?.avatarUrl ?? '';
    var city = _remote?.city.trim() ?? '';
    var languageCode = callLang.lang.isNotEmpty
        ? callLang.lang
        : (_languageCode.isNotEmpty
            ? _languageCode
            : AppStrings.currentBcp47.value);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // Les deux sorties, écrites noir sur blanc : le voile se tape pour
      // fermer, la feuille se tire vers le bas.
      isDismissible: true,
      enableDrag: true,
      // Et de quoi taper à côté : sans plafond, sur un écran court la feuille
      // montait jusqu'au bord haut et il ne restait aucun voile à toucher.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            return _EditAccountSheet(
              displayName: displayName,
              avatarUrl: avatarUrl,
              fallbackUrl: _remote?.fallbackPhotoUrl ?? '',
              city: city,
              languageCode: languageCode,
              onPickAvatar: () async {
                await _pickAndSetAvatar();
                if (!mounted) return;
                setSheet(() => avatarUrl = _remote?.avatarUrl ?? '');
              },
              onRemoveAvatar: () async {
                await _clearAvatar();
                if (!mounted) return;
                setSheet(() => avatarUrl = _remote?.avatarUrl ?? '');
              },
              onEditName: () async {
                await _promptEditName(overlay: sheetCtx);
                if (!mounted) return;
                setSheet(
                  () => displayName = _remote?.displayName.trim() ?? '',
                );
              },
              onEditCity: () async {
                await _promptEditCity(overlay: sheetCtx);
                if (!mounted) return;
                setSheet(() => city = _remote?.city.trim() ?? '');
              },
              onEditLanguage: () async {
                final code =
                    await _promptEditLiveTranslation(overlay: sheetCtx);
                if (!mounted || code == null) return;
                setSheet(() => languageCode = code);
              },
            );
          },
        );
      },
    );
  }

  Future<void> _promptEditName({BuildContext? overlay}) async {
    final ctx = overlay ?? context;
    final current = _remote?.displayName ?? '';
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
              AppStrings.t('name_change_cooldown', args: {'days': '$daysLeft'}),
            ),
          ),
        );
        return;
      }
    }
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: ctx,
      barrierColor: PopupTokens.scrim,
      builder: (dCtx) => SwaycoTextPromptDialog(
        title: AppStrings.t('settings_first_name'),
        controller: ctrl,
        maxLength: profileNameMaxLength,
      ),
    );
    ctrl.dispose();
    if (result == null || !mounted) return;
    await _saveName(result);
  }

  Future<void> _promptEditCity({BuildContext? overlay}) async {
    final ctx = overlay ?? context;
    if (_deviceId.isEmpty || !ctx.mounted) return;
    final result = await showModalBottomSheet<(String, String)>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) => LocationPickerSheet(
        initialCountry: _remote?.country ?? '',
        initialCity: _remote?.city ?? '',
      ),
    );
    if (result == null || !mounted) return;
    final ok = await ProfileApi.updateMyLocation(
      userId: _deviceId,
      country: result.$1,
      city: result.$2,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('save_failed'))),
      );
      return;
    }
    setState(
      () => _remote = _remote?.copyWith(country: result.$1, city: result.$2),
    );
  }

  /// Returns the newly saved call-spoken language code, or null if cancelled.
  Future<String?> _promptEditLiveTranslation({BuildContext? overlay}) async {
    final ctx = overlay ?? context;
    final saved = await UserPrefs.loadCallSpokenLang();
    if (!ctx.mounted) return null;
    final current = saved.lang.isNotEmpty
        ? saved.lang
        : (_languageCode.isNotEmpty
            ? _languageCode
            : AppStrings.currentBcp47.value);
    final langs = callLanguages;
    final start = langs.indexWhere((l) => l.code == callLanguageCode(current));
    final picked = await showWheelPicker(
      context: ctx,
      title: AppStrings.t('settings_live_translation'),
      emoji: '🗣️',
      labels: [for (final l in langs) '${l.flag}  ${l.label}'],
      initialIndex: start < 0 ? 0 : start,
    );
    if (picked == null || !mounted) return null;
    final code = langs[picked].code;
    await UserPrefs.saveCallSpokenLang(code, dontAsk: saved.dontAsk);
    return code;
  }

  @override
  Widget build(BuildContext context) {
    final page = _buildPage(context);
    // La barre du bas ne se range qu'au défilement de MON onglet : le profil
    // d'un autre (et l'aperçu du mien) est poussé par-dessus, sans barre.
    if (widget.userId != null) return page;
    return NavAutoHide(tab: NavTab.profile, child: page);
  }

  /// ⋮ : retirer des amis, signaler, bloquer.
  Widget _moreMenu() {
    return PopupMenuButton<String>(
      tooltip: AppStrings.t('tooltip_more'),
      padding: EdgeInsets.zero,
      color: SC.menu,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: SC.glassBorder),
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
                Icon(
                  Icons.heart_broken_outlined,
                  size: 18,
                  color: SC.textPrimary,
                ),
                const SizedBox(width: 10),
                Text(
                  AppStrings.t('unmatch'),
                  style: TextStyle(
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
      child: const _GlassCircle(icon: Icons.more_vert),
    );
  }

  /// Le marque-page : le bouton change tout de suite, et revient si
  /// l'enregistrement échoue.
  Future<void> _toggleSaved() async {
    if (_targetId.isEmpty || _savingPeer) return;
    final next = !_peerSaved;
    HapticFeedback.selectionClick();
    setState(() {
      _peerSaved = next;
      _savingPeer = true;
    });
    try {
      await SavedProfilesApi.setSaved(_targetId, next);
      if (next) Analytics.track('profile_saved');
    } catch (e) {
      if (!mounted) return;
      setState(() => _peerSaved = !next);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _savingPeer = false);
    }
  }

  Future<void> _loadSaved() async {
    final id = widget.userId;
    if (id == null) return;
    final saved = await SavedProfilesApi.isSaved(id);
    if (mounted && !_savingPeer) setState(() => _peerSaved = saved);
  }

  /// Le profil d'un pair (voir [PeerProfileView]).
  Widget _buildPeer(BuildContext context) {
    final remote = _remote;
    final back = _GlassCircle(
      icon: Icons.arrow_back_rounded,
      onTap: () => Navigator.of(context).maybePop(),
    );
    if (_loading) {
      return Scaffold(
        backgroundColor: SC.bg,
        body: Stack(
          children: [
            Center(child: CircularProgressIndicator(color: SC.accentFg)),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 6,
              left: 14,
              child: back,
            ),
          ],
        ),
      );
    }
    final photos = [
      for (final u in remote?.photos ?? const <String>[])
        if (u.isNotEmpty) u,
    ];
    final avatar = remote?.bestAvatarUrl ?? '';
    final name = _displayName.isEmpty
        ? AppStrings.t('profile_anonymous')
        : _displayName;
    final popular = (remote?.isPro ?? false) || (remote?.isPlus ?? false);
    final passport = (_hasFacts(remote) ||
            (remote?.interests.isNotEmpty ?? false))
        ? remote
        : null;
    return Scaffold(
      body: PeerProfileView(
        profile: remote,
        name: name,
        backgroundUrl: photos.isNotEmpty ? photos.first : avatar,
        avatarUrl: avatar.isNotEmpty
            ? avatar
            : (photos.isNotEmpty ? photos.first : ''),
        online: _peerOnline,
        badge: popular
            ? _PopularPill(
                onAvatar: true,
                message: AppStrings.t('profile_popular_body', args: {
                  'name': name.split(RegExp(r'\s+')).first,
                }),
              )
            : null,
        back: back,
        menu: widget.preview ? const SizedBox.shrink() : _moreMenu(),
        children: [
          // Aperçu de mon profil : aucune action.
          if (!widget.preview)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            // Bloqué par moi : un seul « Débloquer ».
            child: _peerBlocked
                ? PeerPrimaryButton(
                    label: AppStrings.t('unblock'),
                    icon: Icons.lock_open,
                    onTap: _toggleBlock,
                  )
                : PeerActionRow(
                    friends: _matched,
                    requested: _iLiked,
                    onMessage: _openChatWithPeer,
                    onFriend: _peerBlockedMe
                        ? null
                        : (_peerLikedMe ? _acceptPeer : _likePeer),
                    saved: _peerSaved,
                    onSave: _toggleSaved,
                  ),
          ),
          if (remote != null)
            Padding(
              padding: EdgeInsets.fromLTRB(18, widget.preview ? 0 : 18, 18, 0),
              child: PeerBioCard(profile: remote),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
            child: _ProfileSectionHeader(
              AppStrings.t('peer_photos_section'),
              suffix: photos.isEmpty ? '' : '(${photos.length})',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _PeerMediaStack(
              photos: photos,
              profile: passport,
              flush: true,
            ),
          ),
        ],
      ),
    );
  }

  /// Mon profil : la même mise en page que celui des autres (photo en fond,
  /// panneau qui monte), avec de quoi tout modifier.
  Widget _buildMine(BuildContext context) {
    final remote = _remote;
    if (_loading) {
      return Scaffold(
        backgroundColor: SC.bg,
        body: Center(child: CircularProgressIndicator(color: SC.accentFg)),
      );
    }
    final photos = [
      for (final u in remote?.photos ?? const <String>[])
        if (u.isNotEmpty) u,
    ];
    final avatar = remote?.bestAvatarUrl ?? '';
    final name = _displayName.isEmpty
        ? AppStrings.t('profile_anonymous')
        : _displayName;
    final popular = (remote?.isPro ?? false) || (remote?.isPlus ?? false);
    Widget section(Widget child, {double top = 24}) => Padding(
          padding: EdgeInsets.fromLTRB(18, top, 18, 0),
          child: child,
        );
    return Scaffold(
      body: PeerProfileView(
        profile: remote,
        name: name,
        // Le fond est la première photo de la galerie.
        backgroundUrl: photos.isNotEmpty ? photos.first : avatar,
        avatarUrl: avatar.isNotEmpty
            ? avatar
            : (photos.isNotEmpty ? photos.first : ''),
        online: false,
        startExpanded: false,
        bottomInset: GlassNavBar.totalReservedHeight,
        subtitle: Text(
          _handle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 12,
            color: SC.textPrimary.withValues(alpha: 0.75),
          ),
        ),
        badge: popular ? const _PopularPill(onAvatar: true) : null,
        cornerBadge: const _CameraBadge(),
        onAvatarCornerTap: _openEditAccountSheet,
        back: _GlassCircle(
          icon: Icons.arrow_back_rounded,
          // L'onglet n'est pas une page empilée : on revient à Discover.
          onTap: () => NavTab.select(NavTab.discover),
        ),
        menu: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GlassCircle(
              icon: Icons.visibility_outlined,
              tooltip: AppStrings.t('profile_preview'),
              onTap: _openSelfPreview,
            ),
            const SizedBox(width: 8),
            SettingsHeroButton(onOpen: _openSettings),
          ],
        ),
        children: [
          section(
            ProfileViewsCard(
              onOpen: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const ProfileViewsScreen(),
                ),
              ),
            ),
            top: 0,
          ),
          section(
            _ProfileSectionHeader(
              AppStrings.t('profile_photos_section'),
              suffix: photos.isEmpty ? '' : '(${photos.length})',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _PhotoGallery(
              photos: photos,
              onPick: _pickAndAddPhoto,
              onRemove: _removePhoto,
              onReorderPhotos: _reorderPhotos,
            ),
          ),
          section(
            _DiscoverVisibilityHint(
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              ),
            ),
            top: 10,
          ),
          section(
            MyBioCard(
              header: _ProfileSectionHeader(
                AppStrings.t('profile_bio_section'),
              ),
              profile: remote,
              onSaveText: _saveBio,
              onVoiceChanged: () => _reload(silent: true),
              confirm: (title, body, action) async =>
                  await showSwaycoConfirm(
                    context: context,
                    title: title,
                    body: body,
                    confirmLabel: action,
                  ) ==
                  true,
            ),
          ),
          section(_ProfileSectionHeader(AppStrings.t('info_section_title'))),
          section(
            _PersonalInfoSection(
              profile: remote,
              onSave: _savePersonalInfo,
              // Les centres d'intérêt restent DANS la carte.
              bottom: _InterestsSection(
                interests: remote?.interests ?? const [],
                onSave: _saveInterests,
                country: remote?.country ?? '',
              ),
            ),
            top: 12,
          ),
          ValueListenableBuilder<bool>(
            valueListenable: RevenueCat.proActive,
            builder: (_, pro, _) => pro
                ? const SizedBox.shrink()
                : section(const ProBanner()),
          ),
          section(_ProfileSectionHeader(AppStrings.t('contact_title'))),
          section(const _ContactCard(), top: 12),
        ],
      ),
    );
  }

  Widget _buildPage(BuildContext context) => widget.userId != null
      ? _buildPeer(context)
      : _buildMine(context);

  static bool _hasFacts(RemoteProfile? p) =>
      p != null &&
      (p.age != null ||
          p.job.trim().isNotEmpty ||
          p.zodiac.trim().isNotEmpty ||
          p.personaCategory.trim().isNotEmpty ||
          p.originMother.trim().isNotEmpty ||
          p.originFather.trim().isNotEmpty);
}

/// Rond de 44 en verre (blanc 13 %, bord blanc 30 % de 1,2 px, flou 20) — les
/// boutons posés sur la couverture.
/// « POPULAIRE » : pastille jaune posée à côté de la flèche retour d'un profil.
class _PopularPill extends StatelessWidget {
  const _PopularPill({this.message = '', this.onAvatar = false});

  /// Posé au bas de la photo de profil : plus petit, cerné du fond de la page.
  final bool onAvatar;

  /// Le petit texte qui s'affiche quand on reste appuyé sur le badge.
  final String message;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return _pill();
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.longPress,
      showDuration: const Duration(seconds: 4),
      preferBelow: true,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      // Sombre : bulle blanche. Clair : l'ancienne bulle sombre, inchangée.
      decoration: SC.light
          ? BoxDecoration(
              color: const Color(0xF2161A2C),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            )
          : BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(color: Color(0x40000000), blurRadius: 12),
              ],
            ),
      textStyle: TextStyle(
        color: SC.light ? Colors.white : const Color(0xFF04123A),
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
      child: _pill(),
    );
  }

  Widget _pill() {
    // Les mêmes étincelles que le Boost et que « POPULAIRE » sur Discover.
    return Sparkles(
      color: Colors.white,
      count: 5,
      child: _pillBody(),
    );
  }

  Widget _pillBody() {
    return Container(
      padding: onAvatar
          ? const EdgeInsets.symmetric(horizontal: 9, vertical: 3)
          : const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF4FF1F),
        borderRadius: BorderRadius.circular(999),
        border: onAvatar
            ? Border.all(
                color: SC.light
                    ? const Color(0xFFF3F4F8)
                    : const Color(0xFF0E0E0E),
                width: 2,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF4FF1F).withValues(alpha: 0.2),
            blurRadius: 8,
          ),
        ],
      ),
      child: Text(
        AppStrings.t('paywall_popular').toUpperCase(),
        maxLines: 1,
        style: TextStyle(
          color: const Color(0xFF04123A),
          fontSize: onAvatar ? 9.5 : 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _GlassCircle extends StatelessWidget {
  const _GlassCircle({required this.icon, this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final disc = ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            // Clair : rond plein comme les R?glages (? 13 % il disparaissait
            // sur le d?grad? marine du haut). Sombre / Noir : verre + l'anneau
            // de la bulle Filtrer.
            color: light ? SC.fill : SC.fill.withValues(alpha: 0.13),
            boxShadow: SC.lift,
            shape: BoxShape.circle,
            border: light ? Border.all(color: SC.stroke, width: 1.2) : null,
          ),
          child: Icon(icon, size: 22, color: SC.fg),
        ),
      ),
    );
    // Sombre / Noir : anneau de 1 px au degrade de marque, comme « Filtrer »,
    // trace PAR-DESSUS le rond (le fond du rond reste du verre).
    final circle = light
        ? disc
        : CustomPaint(foregroundPainter: const BrandRingPainter(), child: disc);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: tooltip == null ? circle : Tooltip(message: tooltip!, child: circle),
    );
  }
}

/// Un cadre à bord POINTILLÉ (les cases « Ajouter » du profil).
class _DashedBox extends StatelessWidget {
  const _DashedBox({
    required this.child,
    required this.color,
    required this.radius,
    this.fill,
    this.strokeWidth = 1.5,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final Color color;
  final Color? fill;
  final double radius;
  final double strokeWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(
        color: color,
        fill: fill,
        radius: radius,
        strokeWidth: strokeWidth,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.fill,
    required this.radius,
    required this.strokeWidth,
  });

  final Color color;
  final Color? fill;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(strokeWidth / 2),
      Radius.circular(radius),
    );
    if (fill != null) canvas.drawRRect(rrect, Paint()..color = fill!);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final dash = strokeWidth * 3.2;
    final gap = strokeWidth * 2.4;
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth;
}

/// Grille 2 colonnes de photos sur le profil d'un pair. Tap : viewer plein ecran.
class _PeerMediaStack extends StatelessWidget {
  const _PeerMediaStack({
    required this.photos,
    this.profile,
    this.flush = false,
  });

  /// Bord à bord, 2 px d'écart, tuiles droites (profil d'un pair).
  final bool flush;

  final List<String> photos;

  /// Non nul : le passeport ouvre la grille, avant les photos.
  final RemoteProfile? profile;

  // Grille d'avant la DA : 2 colonnes, vignettes 3 / 4 (hauteur / largeur).
  static const double _aspect = 216 / 162;
  static const int _columns = 2;

  @override
  Widget build(BuildContext context) {
    final passport = profile;
    if (photos.isEmpty && passport == null) return const _EmptyPhotosPlaceholder();
    // Le passeport est la page 0 de la visionneuse : les photos suivent.
    final offset = passport != null ? 1 : 0;

    final spacing = flush ? 2.0 : 8.0;
    final radius = flush ? 0.0 : 20.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth =
            (constraints.maxWidth - spacing * (_columns - 1)) / _columns;
        final tileHeight = tileWidth * _aspect;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            if (passport != null)
              SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PassportTile(
                      profile: passport,
                      radius: radius,
                      onTap: () => showPhotoViewer(
                        context,
                        photos: photos,
                        index: 0,
                        viewerMode: true,
                        passportProfile: passport,
                      ),
                    ),
                    if (flush)
                      Positioned(
                        top: 34,
                        right: 8,
                        // ⤢ : la carte complète, sans animation.
                        child: _ExpandPassport(
                          onTap: () => showPhotoViewer(
                            context,
                            photos: photos,
                            index: 0,
                            viewerMode: true,
                            passportProfile: passport,
                            animatePassport: false,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            for (var i = 0; i < photos.length; i++)
              SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _PhotoCell(
                  photoUrl: photos[i],
                  viewerMode: true,
                  radius: radius,
                  onTap: () => showPhotoViewer(
                    context,
                    photos: photos,
                    index: i + offset,
                    viewerMode: true,
                    passportProfile: passport,
                  ),
                  // Chez un pair : aucun lisere. Le cadre cyan dit "ta photo
                  // de profil", ce qui n'a de sens que sur mon propre profil.
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Le petit rond en verre ⤢ posé sur la tuile passeport.
class _ExpandPassport extends StatelessWidget {
  const _ExpandPassport({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.13),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            child: Icon(
              Icons.open_in_full_rounded,
              size: 14,
              color: SC.light ? const Color(0xFF04123A) : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Le rond jaune « appareil photo » posé sur ma photo de profil.
class _CameraBadge extends StatelessWidget {
  const _CameraBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF4FF1F),
        border: Border.all(
          color: SC.light ? const Color(0xFFF3F4F8) : const Color(0xFF0E0E0E),
          width: 3,
        ),
      ),
      padding: const EdgeInsets.all(3),
      child: const FittedBox(
        child: Icon(Icons.photo_camera, color: Color(0xFF04123A)),
      ),
    );
  }
}

/// Section header used across the redesigned profile (capture-1 style):
/// a bold left-aligned title.
/// Adresse de contact de l'équipe.
const String kContactEmail = 'contact-swayco@gmail.com';

/// Carte « Contact » : un appui ouvre le mail à l'équipe ; sans application de
/// mail, l'adresse est copiée.
class _ContactCard extends StatelessWidget {
  const _ContactCard();

  Future<void> _write(BuildContext context) async {
    final uri = Uri(scheme: 'mailto', path: kContactEmail);
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (ok || !context.mounted) return;
    await Clipboard.setData(const ClipboardData(text: kContactEmail));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.t('contact_copied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _write(context),
      child: InfoGlassFrame(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                gradient: SC.brandGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.mail_rounded,
                size: 22,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.t('contact_sub'),
                    style: TextStyle(
                      color: SC.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kContactEmail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: SC.light ? SC.brandBlue : SC.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 24,
              color: SC.light ? SC.textMuted : Colors.white54,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileSectionHeader extends StatelessWidget {
  const _ProfileSectionHeader(this.title, {this.suffix = ''});
  final String title;

  /// Le « (n) » après le titre, en blanc 55 %.
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              text: title,
              children: [
                if (suffix.isNotEmpty)
                  TextSpan(
                    text: ' $suffix',
                    style: TextStyle(
                      color: SC.light
                          ? SC.textMuted
                          : SC.fg.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
            style: popupDisplay(
              fontSize: 17,
              letterSpacing: -0.5,
              color: SC.light ? SC.textPrimary : Colors.white,
            ),
          ),
        ),
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
        color: SC.fill.withValues(alpha: 0.02), boxShadow: SC.lift,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_camera_outlined,
            size: 34,
            color: SC.textMuted,
          ),
          const SizedBox(height: 10),
          Text(
            AppStrings.t('profile_no_photos'),
            style: TextStyle(color: SC.textMuted, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// Full-screen overlay for profile photos. Swipe or use the side arrows to
/// move between several photos; pinch to zoom; the â in the photo's top-right
/// corner (or a tap on the backdrop) dismisses. Plus rien d'autre : la carte
/// Discover déroule toute la galerie, il n'y a donc plus de photo à y désigner
/// — c'est l'ordre des tuiles, réglable au doigt, qui décide.
Future<void> showPhotoViewer(
  BuildContext context, {
  required List<String> photos,
  required int index,
  bool viewerMode = false,
  RemoteProfile? passportProfile,
  bool wholePhoto = false,
  RemoteProfile? footerProfile,
  bool animatePassport = true,
}) {
  if (photos.isEmpty && passportProfile == null) return Future<void>.value();
  final pageCount = photos.length + (passportProfile != null ? 1 : 0);
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim, _) => _PhotoViewer(
        photos: photos,
        initialIndex: index.clamp(0, pageCount - 1),
        viewerMode: viewerMode,
        passportProfile: passportProfile,
        wholePhoto: wholePhoto,
        footerProfile: footerProfile,
        animatePassport: animatePassport,
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
    this.passportProfile,
    this.wholePhoto = false,
    this.footerProfile,
    this.animatePassport = true,
  });

  /// Non nul : sous la photo, les points puis le drapeau, le prénom et le pays.
  final RemoteProfile? footerProfile;
  final bool animatePassport;
  final List<String> photos;
  final int initialIndex;
  final bool viewerMode;

  /// Photo reçue dans le chat : affichée EN ENTIER (contain), pas recadrée au
  /// format de la carte Discover.
  final bool wholePhoto;

  /// Non nul : la page 0 est le passeport, les photos suivent.
  final RemoteProfile? passportProfile;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pc = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  /// L'animation du Discover ne se joue qu'à l'OUVERTURE par un tap sur la
  /// tuile passeport — pas quand on revient dessus en feuilletant les photos
  /// (flèches, glissement gauche / droite).
  late bool _animatePassport = widget.animatePassport &&
      widget.passportProfile != null &&
      widget.initialIndex == 0;

  /// Hauteur dont le passeport a besoin pour tout montrer sans défiler (mesurée
  /// par le panneau) ; null tant qu'elle n'est pas connue.
  double? _passportNeed;

  // Zoom : le glissement de la galerie (PageView) se disputait le geste avec le
  // pincement. Dès que deux doigts sont posés, ou que la photo est agrandie,
  // la galerie ne défile plus — le geste revient au zoom / au déplacement.
  int _pointers = 0;
  bool _zoomed = false;
  final Map<int, TransformationController> _zoomCtrls = {};

  @override
  void dispose() {
    _pc.dispose();
    for (final c in _zoomCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, _pageCount - 1);
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
        // Verre transparent (flou + voile blanc leger) cerne d'un anneau de 1 px
        // au degrade de marque, trace PAR-DESSUS pour ne pas teinter le fond.
        // Clair : le meme bord que les autres boutons du profil.
        child: CustomPaint(
          foregroundPainter: SC.light ? null : const BrandRingPainter(),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                  border: SC.light
                      ? Border.all(
                          color: SC.stroke.withValues(alpha: 0.3),
                          width: 1.2,
                        )
                      : null,
                ),
                child: Icon(icon, color: Colors.white, size: size * 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }

  int get _passportOffset => widget.passportProfile != null ? 1 : 0;
  int get _pageCount => widget.photos.length + _passportOffset;

  /// La page passeport : la vraie carte passeport du Discover, ouverte d'emblée
  /// et sans animation, dans le même cadre que les photos (pas de zoom). Un
  /// appui DANS le cadre ne ferme pas ; le fond, si.
  Widget _passportPage(double frameWide, double frameH) {
    final p = widget.passportProfile!;
    // Une carte PORTRAIT, comme une photo de la grille (3 : 4), et plus étroite
    // que le cadre des photos : les flèches latérales (44 px) ne passent pas
    // dessus. Jamais plus étroite que 0,6 (large / haut) sur un petit écran.
    final mq = MediaQuery.of(context);
    final screenH = mq.size.height;
    final maxH = frameH > screenH * 0.80 ? frameH : screenH * 0.80;
    // Le plus haut que la carte puisse aller (toute la hauteur utile) : elle ne
    // l'atteint que s'il y a trop d'éléments pour tenir à la taille normale.
    final fullH = math.max(
      maxH,
      screenH - mq.padding.top - mq.padding.bottom - 24,
    );
    final maxW = frameWide - 56;
    // 2 px de moins de chaque côté.
    final frameW = (maxH * 0.8 < maxW ? maxH * 0.8 : maxW) - 4;
    final h0 = frameW / 0.58 < maxH ? frameW / 0.58 : maxH;
    // Taille normale ; plus haute seulement si le contenu l'exige (jamais plus
    // que l'écran). Quelqu'un qui a peu d'éléments garde la taille normale.
    final need = _passportNeed;
    final h = need == null ? h0 : need.clamp(h0, math.max(h0, fullH)).toDouble();
    return Center(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: SizedBox(
              width: frameW,
              height: h,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ProfileInfoPanel(
                  profile: p,
                  open: true,
                  hideFlag: false,
                  // L'animation du Discover (couverture, blocs, tampon), et
                  // une marge basse réduite : ici pas de boutons ✕ / ❤.
                  animateOnMount: _animatePassport,
                  onContentHeight: (v) {
                    if (mounted && _passportNeed != v) {
                      setState(() => _passportNeed = v);
                    }
                  },
                  bottomPadding: 28,
                  alwaysScrollable: false,
                  // La place du ✕ du visionneur, à droite du bandeau.
                  bandInsetRight: 58,
                  onClose: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
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
    );
  }

  Widget _photoPage(int i, double frameW, double frameH) =>
      GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Cadre FIXE au format de la carte Discover : toutes les
                    // photos s'affichent pareil, recadrées (cover).
                    SizedBox(
                      width: frameW,
                      height: frameH,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: InteractiveViewer(
                          transformationController: _zoomCtrls.putIfAbsent(
                            i,
                            TransformationController.new,
                          ),
                          minScale: 1,
                          maxScale: 4,
                          onInteractionEnd: (_) {
                            final z = (_zoomCtrls[i]?.value
                                        .getMaxScaleOnAxis() ??
                                    1) >
                                1.02;
                            if (z != _zoomed && mounted) {
                              setState(() => _zoomed = z);
                            }
                          },
                          child: Image.network(
                            widget.photos[i],
                            fit: widget.wholePhoto
                                ? BoxFit.contain
                                : BoxFit.cover,
                            width: frameW,
                            height: frameH,
                            errorBuilder: (_, _, _) => Padding(
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
                    // â in the photo's top-right corner.
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
            );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final multi = _pageCount > 1;
    // Le cadre : pleine largeur (14 de marge) au ratio de la carte Discover,
    // borné en hauteur pour laisser respirer l'écran.
    final aspect = discoverCardAspect(context);
    var frameW = size.width - 28;
    var frameH = frameW / aspect;
    // Le bas (points, nom) prend sa place sous la photo.
    final footer = widget.footerProfile;
    final footerH = footer == null ? 0.0 : 84.0;
    final maxH = size.height * (footer == null ? 0.82 : 0.72);
    if (frameH > maxH) {
      frameH = maxH;
      frameW = frameH * aspect;
    }
    // Photo de chat : tout l'espace disponible, l'image y tient en entier.
    if (widget.wholePhoto) {
      frameW = size.width - 28;
      frameH = maxH;
    }
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.78),
      body: Stack(
        children: [
          Positioned.fill(
            bottom: footerH,
            child: Listener(
            onPointerDown: (_) => setState(() => _pointers++),
            onPointerUp: (_) =>
                setState(() => _pointers = (_pointers - 1).clamp(0, 10)),
            onPointerCancel: (_) =>
                setState(() => _pointers = (_pointers - 1).clamp(0, 10)),
            child: PageView.builder(
              padEnds: true,
              controller: _pc,
              itemCount: _pageCount,
              physics: (_pointers >= 2 || _zoomed)
                  ? const NeverScrollableScrollPhysics()
                  : null,
              onPageChanged: (i) => setState(() {
                _index = i;
                _animatePassport = false;
                _zoomed = false;
                // Page quittée : elle revient à sa taille d'origine.
                for (final c in _zoomCtrls.values) {
                  c.value = Matrix4.identity();
                }
              }),
              itemBuilder: (ctx, pi) => pi < _passportOffset
                  ? _passportPage(frameW, frameH)
                  : _photoPage(pi - _passportOffset, frameW, frameH),
            ),
            ),
          ),
          // Side arrows when there's more than one photo.
          if (multi) ...[
            Positioned(
              left: 6,
              top: 0,
              bottom: footerH,
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
              bottom: footerH,
              child: Center(
                child: _circleBtn(
                  Icons.chevron_right_rounded,
                  _index < _pageCount - 1 ? () => _go(1) : null,
                  size: 44,
                ),
              ),
            ),
          ],
          if (footer != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 18,
              child: IgnorePointer(
                child: _ViewerFooter(
                  profile: footer,
                  count: _pageCount,
                  index: _index,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Sous la photo ouverte depuis le fil : les points, puis le drapeau, le prénom
/// et le pays.
class _ViewerFooter extends StatelessWidget {
  const _ViewerFooter({
    required this.profile,
    required this.count,
    required this.index,
  });

  final RemoteProfile profile;
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.trim();
    final first = name.isEmpty ? '' : name.split(RegExp(r'\s+')).first;
    final country = profile.country.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (count > 1)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < count; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: i == index ? 20 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    decoration: BoxDecoration(
                      color: Colors.white
                          .withValues(alpha: i == index ? 1 : 0.4),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RoundFlag(
              country: country,
              language: profile.language,
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                [first, country].where((s) => s.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Tes photos" â a horizontal gallery of portrait photo tiles (capture-1
/// style). On my own profile the first tile is the yellow/accent "+" add
/// CTA, followed by each photo with a delete badge; the PDP (index 0) also
/// carries the private likes badge. In viewer mode the gallery is read-only
/// (the PDP carries the like-this-peer heart). Reuses [_PhotoCell] for the
/// photo + its badges and [_AddDiscoverPhotoCta] for the add tile.
class _PhotoGallery extends StatelessWidget {
  const _PhotoGallery({
    required this.photos,
    required this.onPick,
    required this.onRemove,
    this.onReorderPhotos,
  });

  final List<String> photos;

  final VoidCallback onPick;
  final void Function(String url) onRemove;
  // Own profile: reorder the gallery by dragging a tile (final positions).
  final void Function(int from, int to)? onReorderPhotos;

  // Portrait tiles (3:4) â a single horizontal, scrollable row of larger tiles.
  static const double _spacing = 8;

  @override
  Widget build(BuildContext context) {
    final canAdd = photos.length < profilePhotosMax;
    // "Tes photos" agrandies : une rangÃ©e horizontale de grandes tuiles (la
    // tuile "+" d'abord), qu'on fait dÃ©filer.
    const double tileWidth = 158;
    const double tileHeight = 158 * 4 / 3;
    final count = (canAdd ? 1 : 0) + photos.length;
    final offset = canAdd ? 1 : 0;
    return SizedBox(
      height: tileHeight,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        // Pas de poignée dessinée : c'est l'appui long SUR la photo qui la
        // décroche (voir ReorderableDelayedDragStartListener plus bas). Une
        // poignée sur une grille de photos n'aurait nulle part où se poser.
        buildDefaultDragHandles: false,
        // Le doigt décroche la tuile : petit coup sec, elle grossit et prend
        // une ombre — c'est ce qui fait qu'on la sent quitter la rangée. Au
        // repos, un second cran plus discret confirme qu'elle est reposée.
        onReorderStart: (_) {
          HapticFeedback.mediumImpact();
          SwaycoSounds.play(SwSound.reorderPick);
        },
        onReorderEnd: (_) {
          HapticFeedback.selectionClick();
          SwaycoSounds.play(SwSound.reorderDrop);
        },
        proxyDecorator: (child, index, animation) => AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final t = Curves.easeOut.transform(animation.value);
            return Transform.scale(
              scale: 1 + 0.06 * t,
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                shadowColor: Colors.black,
                elevation: 18 * t,
                child: child,
              ),
            );
          },
        ),
        // onReorder, et PAS onReorderItem : ce dernier n'existe qu'à partir de
        // Flutter 3.47, que la chaîne de build ne peut pas prendre tant que
        // livekit_client 2.7.0 ne compile pas dessus (worktree 3.41.2 en local,
        // FLUTTER_VERSION 3.41.2 sur la CI iOS). onReorder donne un newIndex
        // calculé AVANT le retrait de la tuile — le -1 en descente refait ce
        // que onReorderItem faisait tout seul, le comportement est identique.
        onReorder: (oldIndex, newIndex) {
          final move = onReorderPhotos;
          if (move == null) return;
          if (newIndex > oldIndex) newIndex -= 1;
          final from = oldIndex - offset;
          final to = newIndex - offset;
          // La tuile "+" ne se déplace pas, et rien ne se glisse devant elle.
          if (from < 0) return;
          move(from, to < 0 ? 0 : to);
        },
        itemCount: count,
        itemBuilder: (context, index) {
          if (canAdd && index == 0) {
            return Padding(
              key: const ValueKey('add-photo-tile'),
              padding: const EdgeInsets.only(right: _spacing),
              child: SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _AddDiscoverPhotoCta(onTap: onPick),
              ),
            );
          }
          final photoIndex = index - offset;
          final url = photos[photoIndex];
          // L'écart entre tuiles est porté par chaque tuile (une
          // ReorderableListView n'a pas de separatorBuilder) ; la dernière n'en
          // met pas, sinon la rangée traînerait un vide à son bout.
          return Padding(
            key: ValueKey(url),
            padding: EdgeInsets.only(
              right: photoIndex == photos.length - 1 ? 0 : _spacing,
            ),
            child: ReorderableDelayedDragStartListener(
              index: index,
              child: SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _PhotoCell(
                  photoUrl: url,
                  viewerMode: false,
                  onTap: () => showPhotoViewer(
                    context,
                    photos: photos,
                    index: photoIndex,
                  ),
                  onDelete: () => onRemove(url),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Inline, in-place text editor â no bottom sheet. Shows [value] (or the
/// [placeholder] when empty) as centred tappable text; tapping turns it into
/// a centred field that commits on submit (keyboard "done") or when focus
/// leaves. Reused for the name and the bio on my own profile.
/// Les 5 faits optionnels du profil, Ã©ditables en place. Une ligne vide se lit
/// "Ajouter" : rien n'est obligatoire, et un champ vidÃ© disparaÃ®t du panneau
/// que la carte Discover dÃ©plie.
class _PersonalInfoSection extends StatelessWidget {
  const _PersonalInfoSection({
    required this.profile,
    required this.onSave,
    this.bottom,
  });

  /// Rendu en bas de la carte : les centres d'intérêt.
  final Widget? bottom;

  final RemoteProfile? profile;
  final Future<void> Function({
    Object? age,
    Object? heightCm,
    Object? job,
    Object? zodiac,
    Object? personaCategory,
    Object? nationality,
    Object? originMother,
    Object? originFather,
  })? onSave;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final save = onSave;
    if (save == null) return const SizedBox.shrink();
    // La catégorie choisie porte son propre emoji : c'est LUI qui tient la
    // colonne de gauche de la ligne. La coupe n'est que le pictogramme du
    // champ vide — une fois "Mélomane" choisi, la ligne s'annonce en 🎵.

    Future<void> pickAge(BuildContext ctx) async {
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
    }

    Future<void> pickJob(BuildContext ctx) async {
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
    }

    Future<void> pickPersona(BuildContext ctx) async {
      final current = p?.personaCategory ?? '';
      final currentIndex = kPersonaCategoryLabels.indexOf(current);
      final picked = await showWheelPicker(
        context: ctx,
        title: AppStrings.t('info_persona_category'),
        emoji: kFactEmojiPersonaCategory,
        labels: [
          for (final cat in kPersonaCategories)
            '${cat.emoji} ${personaCategoryLabel(cat.label)}',
        ],
        initialIndex: currentIndex < 0 ? 0 : currentIndex,
        allowClear: current.isNotEmpty,
      );
      if (picked == null) return;
      if (picked < 0) {
        await save(personaCategory: '');
        return;
      }
      await save(personaCategory: kPersonaCategoryLabels[picked]);
    }

    Future<void> pickZodiac(BuildContext ctx) async {
      final current = normalizeZodiac(p?.zodiac ?? '');
      final picked = await showWheelPicker(
        context: ctx,
        title: AppStrings.t('info_zodiac'),
        emoji: kFactEmojiZodiac,
        labels: [
          // Les mois seulement dans la roulette — la carte montre le signe seul.
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
    }

    Future<void> pickMother(BuildContext ctx) async {
      final iso = await pickCountryIso(
        ctx,
        title: AppStrings.t('info_origin_mother'),
        current: p?.originMother ?? '',
      );
      if (iso == null) return;
      await save(originMother: iso);
    }

    Future<void> pickFather(BuildContext ctx) async {
      final iso = await pickCountryIso(
        ctx,
        title: AppStrings.t('info_origin_father'),
        current: p?.originFather ?? '',
      );
      if (iso == null) return;
      await save(originFather: iso);
    }

    return InfoGlassFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProfileInfoCard(
            profile: p,
            showHeader: false,
            framed: false,
            editable: true,
            onAge: pickAge,
            onJob: pickJob,
            onZodiac: pickZodiac,
            onPersona: pickPersona,
            onMother: pickMother,
            onFather: pickFather,
            interestsBody: bottom,
          ),
        ],
      ),
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
  });
  final String value;
  final String placeholder;
  final Future<void> Function(String) onSave;
  final int maxLength;

  /// Text style used both for the display text and the field â so editing
  /// looks like the static text it replaces.
  final TextStyle style;

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
            maxLines: 1,
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
      maxLines: 1,
      cursorColor: SC.accentFg,
      textInputAction: TextInputAction.done,
      style: widget.style.copyWith(color: SC.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.placeholder,
        hintStyle: TextStyle(color: SC.textMuted),
        counterText: '',
        filled: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: SC.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: SC.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: SC.accentFg, width: 1.5),
        ),
      ),
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) => _commit(),
    );
  }
}

/// A "centre d'intÃ©rÃªt" chip â a category-coloured pill. Used both on the
/// profile (display) and, with [selected], inside the picker. Tapping it on
/// my own profile opens the picker.
/// The "+ Ajouter" chip that opens the interest picker on my own profile.
class _InterestAddChip extends StatelessWidget {
  const _InterestAddChip({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _DashedBox(
        color: SC.accent.withValues(alpha: 0.6),
        fill: SC.accent.withValues(alpha: 0.12),
        radius: 999,
        strokeWidth: 1.2,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, color: SC.accentFg, size: 17),
            const SizedBox(width: 4),
            Text(
              AppStrings.t('interests_add'),
              style: TextStyle(
                color: SC.accentFg,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
/// The "Centres d'intÃ©rÃªt" section on my own profile: the picked chips plus
/// an "add" chip. Tapping either UNFOLDS the category picker inline, right
/// under the chips (no overlay / bottom sheet) â pick the tags, then tap
/// "Enregistrer" to fold it back and persist. Enforces [profileInterestsMax].
class _InterestsSection extends StatefulWidget {
  const _InterestsSection({
    required this.interests,
    required this.onSave,
    this.country = '',
  });

  final List<String> interests;
  final Future<void> Function(List<String>)? onSave;

  /// The user's country â selects which interests taxonomy the picker shows.
  final String country;

  @override
  State<_InterestsSection> createState() => _InterestsSectionState();
}

class _InterestsSectionState extends State<_InterestsSection> {
  late Set<String> _sel = {...widget.interests};

  /// Vrai pendant que la feuille est ouverte : la sÃ©lection en cours est celle
  /// de l'utilisateur, on ne la rÃ©aligne pas sur le parent tant qu'il choisit.
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

  // Auto-persist on every tap â the picker has no mandatory "Save" step, so
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

  /// Le sÃ©lecteur s'ouvre PAR-DESSUS la page, dans une feuille modale. En
  /// ligne, il poussait tout le contenu vers le bas et dÃ©bordait sous la barre
  /// de navigation.
  Future<void> _openPicker() async {
    setState(() => _picking = true);
    // Une POP-UP, pas une feuille : la feuille modale montait du bas et prenait
    // toute la hauteur de l'Ã©cran, contenu collÃ© en haut et grand vide noir en
    // dessous. Un dialogue se pose au centre et fait exactement la taille du
    // panneau, qui est fixe (une page de catÃ©gorie + les points + le bouton).
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: PopupTokens.scrim,
      builder: (sheetCtx) => StatefulBuilder(
        // La feuille a son propre cycle de rendu : sans ce setState local, les
        // puces cochées ne changeraient d'état qu'à la fermeture.
        builder: (sheetCtx, setSheetState) => _InlineInterestPicker(
          sel: _sel,
          onToggle: (tag) {
            _toggle(tag);
            setSheetState(() {});
          },
          onClear: () {
            setState(() => _sel = {});
            widget.onSave?.call(const <String>[]);
            setSheetState(() {});
          },
          onDone: () => Navigator.of(sheetCtx).pop(),
          country: widget.country,
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
        // Le libellé de la case, comme les autres lignes d'infos.
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '$kFactEmojiInterests ${AppStrings.t('profile_interests_section').toUpperCase()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: bentoLabelStyle(),
          ),
        ),
        // Les chips choisis + le chip "Ajouter". N'importe lequel ouvre la
        // feuille de sÃ©lection, qui se pose PAR-DESSUS la page.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in _sel)
              InterestPill(
                label: interestPillText(tag),
                prominent: true,
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

/// La feuille « Intérêts » (proposition C) : le bac « Mes choix » en haut, puis
/// un carrousel de catégories (flèches rondes, points, balayage). Chaque appui
/// est enregistré par [_InterestsSection] ; « Enregistrer » ne fait que refermer.
class _InlineInterestPicker extends StatefulWidget {
  const _InlineInterestPicker({
    required this.sel,
    required this.onToggle,
    required this.onClear,
    required this.onDone,
    this.country = '',
  });

  final Set<String> sel;
  final void Function(String tag) onToggle;
  final VoidCallback onClear;
  final VoidCallback onDone;

  /// Le pays de la personne : choisit la liste d'intérêts.
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

  Widget _round(IconData icon, bool enabled, VoidCallback onTap) {
    return PadTap(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: PopupTokens.ghost,
          // Bordure bleue de marque : plus franche en sombre, bleu 1F5EFF en clair.
          border: Border.all(
            color: SC.light
                ? const Color(0x991F5EFF)
                : SC.brandBlue.withValues(alpha: 0.85),
            width: 1.4,
          ),
        ),
        child: Icon(
          icon,
          size: 22,
          color: enabled
              ? PopupTokens.ink
              : PopupTokens.inkMuted.withValues(alpha: 0.4),
        ),
      ),
    );
  }

  /// Un choix dans le bac : la pastille de l'app + une croix ; un appui la retire.
  Widget _picked(String tag) {
    final light = SC.light;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onToggle(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: light ? const Color(0xFFF2F6FF) : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: light
                ? const Color(0x381F5EFF)
                : Colors.white.withValues(alpha: 0.20),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              interestPillText(tag),
              maxLines: 1,
              softWrap: false,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: PopupTokens.ink,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.close_rounded,
              size: 15,
              color: PopupTokens.ink.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cats = interestCategoriesFor(widget.country);
    final page = _page.clamp(0, cats.length - 1);
    final cat = cats[page];
    final full = widget.sel.length >= profileInterestsMax;
    final light = SC.light;
    final canPrev = page > 0;
    final canNext = page < cats.length - 1;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return PopupSurface(
      sheet: true,
      washHeight: light ? 230 : 140,
      wash: light
          ? (blue: 0.50, cyan: 0.20)
          : (blue: 0.50, cyan: 0.10),
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 12, 18, 26 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: PopupHandle()),
            // ── Mes choix ─────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    AppStrings.t('interests_my_picks', args: {
                      'n': '${widget.sel.length}',
                      'max': '$profileInterestsMax',
                    }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      color: PopupTokens.inkSecondary,
                    ),
                  ),
                ),
                if (widget.sel.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClear,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        AppStrings.t('interests_clear_all'),
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: PopupTokens.inkSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _DashedBox(
              color: light
                  ? const Color(0x4D1F5EFF)
                  : Colors.white.withValues(alpha: 0.22),
              fill: PopupTokens.ghost,
              radius: 18,
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.all(10),
                alignment: Alignment.centerLeft,
                child: widget.sel.isEmpty
                    ? Text(
                        AppStrings.t('interests_empty_hint',
                            args: {'max': '$profileInterestsMax'}),
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: PopupTokens.inkMuted,
                        ),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in widget.sel) _picked(tag),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            // ── Catégorie + flèches rondes ────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${cat.emoji} ${interestLabel(cat.label)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: popupDisplay(
                      fontSize: 17,
                      letterSpacing: -0.51,
                      color: PopupTokens.ink,
                    ),
                  ),
                ),
                _round(Icons.chevron_left_rounded, canPrev,
                    () => _goTo(page - 1)),
                const SizedBox(width: 8),
                _round(Icons.chevron_right_rounded, canNext,
                    () => _goTo(page + 1)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
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
            // ── Points ────────────────────────────────────────────────────
            const SizedBox(height: 14),
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
                        width: i == page ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == page
                              ? (light ? const Color(0xFF1F5EFF) : SC.accent)
                              : PopupTokens.inkMuted.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    if (i != cats.length - 1) const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            PopupButton(
              label: AppStrings.t('save'),
              height: 54,
              onPressed: widget.onDone,
            ),
          ],
        ),
      ),
    );
  }
}

/// Une page du carrousel : les puces d'UNE catégorie (défilement vertical si
/// elles dépassent la hauteur de la zone).
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
    return SingleChildScrollView(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final opt in cat.options)
            InterestPickChip(
              label: interestPillText(opt),
              selected: sel.contains(opt),
              // Limite atteinte : seules les puces déjà choisies restent actives.
              dimmed: !sel.contains(opt) && full,
              onTap: () => onToggle(opt),
            ),
        ],
      ),
    );
  }
}

/// Build a rich span from [raw], rendering any run wrapped in `**â¦**` in the
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
              ? TextStyle(color: SC.accentFg, fontWeight: FontWeight.w600)
              : null,
        ),
    ],
  );
}

/// Small â + text row rendered under the Discover photo tile on the
/// user's own profile. Taps jump to Settings, where the "Hide me
/// from my country" toggle lives â keeps the profile clean while
/// still pointing the user at the visibility control.
class _DiscoverVisibilityHint extends StatelessWidget {
  const _DiscoverVisibilityHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = SC.fgA(0.6);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.visibility_off_outlined, size: 17, color: muted),
            const SizedBox(width: 8),
            Expanded(
              // Les mots entre ** ** (app_strings) sont mis en avant.
              child: Text.rich(
                _highlightKeywords(AppStrings.t('discover_visibility_hint')),
                style: TextStyle(
                  color: muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: muted),
          ],
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
    // Bord pointillé jaune, fond jaune 7 %, rond jaune au centre.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _DashedBox(
        color: SC.accent.withValues(alpha: 0.6),
        fill: SC.accent.withValues(alpha: 0.07),
        radius: 20,
        child: Center(
          child: Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              color: SC.accent,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.add_rounded,
              color: SC.onAccent,
              size: 25,
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
    this.radius = 20,
  });

  final double radius;
  final String? photoUrl;
  final bool viewerMode;
  final VoidCallback onTap;

  /// When non-null and a photo is set on my own profile, a small trash
  /// button appears top-right to delete the photo.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    final tappable = !viewerMode;
    // Trash button: only on my own profile when a photo is actually set.
    final showDeleteAction = !viewerMode && hasPhoto && onDelete != null;
    return Material(
      color: SC.menu,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InkWell(
            // A real photo is always tappable to open it full-screen â on a
            // peer's profile (viewer mode) too, not just my own. Only the
            // empty "add" cell is gated to my own profile (tappable).
            onTap: (hasPhoto || tappable) ? onTap : null,
            child: hasPhoto
                ? Image.network(
                    photoUrl!,
                    fit: BoxFit.cover,
                    frameBuilder: popInFrameBuilder,
                    errorBuilder: (_, _, _) => Center(
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
          if (showDeleteAction)
            Positioned(
              right: 4,
              top: 4,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: PadInkWell(
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
        ],
      ),
    );
  }
}

/// Bottom sheet opened by the PDP pencil — same chrome as the language wheel
/// (handle, dark panel, rounded top). Avatar on top, then name / city / live lang.
class _EditAccountSheet extends StatelessWidget {
  const _EditAccountSheet({
    required this.displayName,
    required this.avatarUrl,
    this.fallbackUrl = '',
    required this.city,
    required this.languageCode,
    required this.onPickAvatar,
    required this.onRemoveAvatar,
    required this.onEditName,
    required this.onEditCity,
    required this.onEditLanguage,
  });

  final String displayName;
  final String avatarUrl;

  /// Photo Discover en repli quand [avatarUrl] est vide ou mort.
  final String fallbackUrl;
  final String city;
  final String languageCode;
  final VoidCallback onPickAvatar;

  /// Retire la PDP dédiée (la ✕ en haut à droite de la bulle) — visible
  /// seulement quand [avatarUrl] est renseignée.
  final VoidCallback onRemoveAvatar;
  final VoidCallback onEditName;
  final VoidCallback onEditCity;
  final VoidCallback onEditLanguage;

  @override
  Widget build(BuildContext context) {
    // La langue d'APPEL : « Português (Brasil) » ou « (Portugal) », pas « Português ».
    final lang = findCallLanguageByCode(languageCode);
    final langLabel = lang == null ? '—' : '${lang.flag}  ${lang.label}';
    final name = displayName.isEmpty
        ? AppStrings.t('profile_anonymous')
        : displayName;
    return _DragDownToClose(
      child: ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: ColoredBox(
        color: PopupTokens.surface,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: SC.fill.withValues(alpha: 0.22), boxShadow: SC.lift,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 18),
              // Même bulle qu'en haut du profil, pastille comprise : c'est ici
              // qu'on vient changer sa photo, et sans la pastille la bulle ne
              // disait pas qu'elle se touchait.
              Stack(
                alignment: Alignment.bottomRight,
                clipBehavior: Clip.none,
                children: [
                  ProfileAvatar(
                    displayName: name,
                    avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
                    fallbackUrl: fallbackUrl.isEmpty ? null : fallbackUrl,
                    size: 88,
                    fontSize: 36,
                    onTap: onPickAvatar,
                  ),
                  // 22 et non 28 : la bulle fait 88 ici contre 128 là-haut, la
                  // pastille garde la même part d'elle.
                  IgnorePointer(
                    child: Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: SC.accentSoft,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: PopupTokens.surface,
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        size: 11,
                        color: SC.onAccent,
                      ),
                    ),
                  ),
                  // ✕ en haut à droite — seulement quand une PDP dédiée est
                  // posée : elle la retire (repli sur la photo Discover).
                  if (avatarUrl.isNotEmpty)
                    Positioned(
                      top: -1,
                      right: -1,
                      child: PadTap(
                        behavior: HitTestBehavior.opaque,
                        onTap: onRemoveAvatar,
                        child: Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2E),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: PopupTokens.surface,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            size: 13,
                            color: SC.fg,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: popupDisplay(
                  color: SC.fg,
                  fontSize: 18,
                  letterSpacing: -0.5,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    AppStrings.t('settings_section_account'),
                    style: TextStyle(
                      color: SC.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: PopupTokens.ghost,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      _EditAccountRow(
                        icon: Icons.badge_outlined,
                        label: AppStrings.t('settings_first_name'),
                        value: displayName.isEmpty ? '—' : displayName,
                        onTap: onEditName,
                      ),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: SC.stroke.withValues(alpha: 0.08),
                      ),
                      _EditAccountRow(
                        icon: Icons.location_city_outlined,
                        label: AppStrings.t('settings_city'),
                        value: city.isEmpty ? '—' : city,
                        onTap: onEditCity,
                      ),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: SC.stroke.withValues(alpha: 0.08),
                      ),
                      _EditAccountRow(
                        // Une icône de l'app et non l'emoji 📞, qui arrivait
                        // avec ses propres couleurs — un combiné gris sale au
                        // milieu de deux glyphes blancs.
                        icon: Icons.call_outlined,
                        label: AppStrings.t('settings_live_translation'),
                        value: langLabel,
                        onTap: onEditLanguage,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Rabat la feuille qui la porte d'un glissement vers le bas — coup sec (120
/// px/s) OU 56 px parcourus, les mêmes seuils que le panneau du Discover. Le
/// glissement natif de showModalBottomSheet demande, lui, un vrai coup sec :
/// un glissement lent mourait à zéro de vélocité et ne fermait rien.
class _DragDownToClose extends StatefulWidget {
  const _DragDownToClose({required this.child});

  final Widget child;

  @override
  State<_DragDownToClose> createState() => _DragDownToCloseState();
}

class _DragDownToCloseState extends State<_DragDownToClose> {
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragStart: (_) => _dy = 0,
      onVerticalDragUpdate: (d) => _dy += d.delta.dy,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 120 || _dy > 56) {
          Navigator.of(context).maybePop();
        }
      },
      child: widget.child,
    );
  }
}

/// "Mon abonnement" — opens the paywall sheet. The trailing tick follows
/// [RevenueCat.proActive], so it updates right after a purchase / restore.
class _EditAccountRow extends StatelessWidget {
  const _EditAccountRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: SC.textPrimary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: SC.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Largeur PLAFONNÉE, pas partagée. En Flexible, la valeur prenait
            // la moitié de l'espace libre au même titre que le libellé : elle
            // commençait donc au milieu de la ligne quel que soit sa longueur,
            // et avait l'air centrée. Bornée, elle est poussée contre le
            // chevron par le libellé, qui absorbe tout le reste.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(color: SC.textMuted, fontSize: 14),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 20, color: SC.textMuted),
          ],
        ),
      ),
    );
  }
}
