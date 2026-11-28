import 'dart:async';

import '../services/notif_enable_flow.dart';
import 'dart:math' as math;
import 'dart:math' show Random;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../widgets/tap_pad.dart';
import '../widgets/load_failed_view.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/ad_service.dart';
import '../services/analytics.dart';
import '../services/app_boot.dart';
import '../services/app_strings.dart';
import '../services/swayco_sounds.dart';
import '../services/chat_api.dart';
import '../services/device_id.dart';
import '../services/friendship_api.dart';
import '../services/count_format.dart';
import '../services/globe_places.dart';
import '../services/languages.dart';
import '../services/like_undo.dart';
import '../services/locations.dart';
import '../services/local_notifications.dart';
import '../services/match_celebration.dart';
import '../services/persona_categories.dart';
import '../services/nav_chrome.dart';
import '../services/nav_tab.dart';
import '../services/profile_api.dart';
import '../services/revenue_cat.dart';
import '../services/rewarded_video.dart';
import '../services/supabase_service.dart';
import '../services/user_prefs.dart';
import '../services/web_poll.dart';
import '../theme/swayco_theme.dart';
import '../widgets/ad_info_sheet.dart';
import '../widgets/country_silhouette.dart';
import '../widgets/discover_feed.dart';
import '../widgets/new_contact_gate.dart';
import '../widgets/discover_globe.dart';
import '../services/fact_emojis.dart';
import '../widgets/info_bento.dart' show bentoLabelStyle;
import '../widgets/profile_info_card.dart';
import '../widgets/glass_nav_bar.dart';
import '../widgets/interest_chip.dart';
import '../widgets/lottie_icon_transition.dart';
import '../widgets/popup_kit.dart' show popupDisplay;
import '../widgets/sent_confirmation.dart';
import '../widgets/sparkles.dart';
import '../widgets/swayco_wordmark.dart';
import '../widgets/translated_profile_text.dart';
import '../widgets/voice_intro_player.dart';
import 'paywall_screen.dart';
import '../services/daily_swipes.dart';
import '../widgets/daily_limit_view.dart';
import 'profile_screen.dart';
import '../services/friendly_error.dart';

/// Le fond du panneau déplié : opaque, un cran au-dessus du noir de la page —
/// assez pour qu'on voie où il commence quand il recouvre la photo, assez peu
/// pour rester du noir.

/// Marge latérale de la carte (handoff 3c).
const double _kCardInset = 14.0;

/// Width / height of the Discover card on THIS device (same maths as
/// [_DiscoverScreenState.build]: screen minus logo, country row, action row
/// and nav). Lets the photo cropper frame exactly what the card will show.
double discoverCardAspect(BuildContext context) {
  final mq = MediaQuery.of(context);
  // 74 : la hauteur qu'avait la rangée de pays sous la carte à glisser.
  final top = mq.padding.top + _DiscoverHeader.height + 74;
  final bottom = GlassNavBar.totalReservedHeight +
      mq.padding.bottom +
      _kActionPadV +
      _kActionSize +
      _kActionPadV;
  final h = mq.size.height - top - bottom;
  final w = mq.size.width - 2 * _kCardInset;
  if (h <= 0 || w <= 0) return 0.66;
  return w / h;
}

/// Rayon des coins de la carte photo (handoff 3c).
const double _kCardRadius = 32.0;
/// Diamètre des boutons ✕ / message / ❤.
const double _kActionSize = 58.0;

/// Respiration au-dessus et au-dessous de la rangée ✕ / message / ❤.
const double _kActionPadV = 16.0;

/// Le push « veut te matcher » d'un like part avec ce retard : le temps de
/// laisser « retour » reprendre le like avant que l'autre soit prévenu.
const Duration _kLikePushDelay = Duration(minutes: 3);

/// Surfaces pleines du handoff : bulles pays, bouton message.
Color get _kSurface =>
    SC.light
        ? const Color(0xFFF8F9FC)
        : (SC.classic ? const Color(0xFF1A1A1D) : const Color(0xFF161D30));

// ══════════════════════════════════════════════════════════════════════════════
// DiscoverScreen
// ══════════════════════════════════════════════════════════════════════════════

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});
  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  List<RemoteProfile> _profiles = const [];
  bool _feedLoading = true;

  /// Le chargement des profils a ÉCHOUÉ (réseau / serveur) — à ne pas confondre
  /// avec « il n'y a personne » (écran « Impossible de charger les profils »).
  bool _loadFailed = false;
  final List<({RemoteProfile profile, List<String> photos})> _cards = [];

  final _scroll = ScrollController();

  void _retryLoad() {
    setState(() {
      _loadFailed = false;
      _feedLoading = true;
    });
    if (_filtered) {
      _loadFeed(countries: _filterCountries);
    } else {
      _bootstrap();
    }
  }

  /// Mes amis : ils n'ont plus à être découverts, au chargement du fil.
  Set<String> get _friendIds => {
        for (final f in _myFriendships)
          if (f.status == 'accepted' && f.peerOf(_myId).isNotEmpty)
            f.peerOf(_myId),
      };

  void _rebuildCards() {
    _cards.clear();
    final friends = _friendIds;
    for (final p in _profiles) {
      if (friends.contains(p.id)) continue;
      // Le genre ne filtre que le deck des pays choisis ; sans pays, tout le
      // monde (un choix mémorisé ne doit pas rester appliqué en silence).
      if (_filtered && _gender == GenderFilter.homme && p.gender != 'm') continue;
      if (_filtered && _gender == GenderFilter.femme && p.gender != 'f') continue;
      var photos = p.photos.where((u) => u.isNotEmpty).toList();
      if (photos.isEmpty && p.discoverPhotoUrl.isNotEmpty) {
        photos = [p.discoverPhotoUrl];
      } else if (photos.isEmpty && p.avatarUrl.isNotEmpty) {
        photos = [p.avatarUrl];
      }
      if (photos.isNotEmpty) _cards.add((profile: p, photos: photos));
    }
    if (_cards.isNotEmpty && !_filtered) {
      UserPrefs.saveDiscoverDeck([for (final c in _cards) c.profile.id]);
    }
  }

  /// Reload today's cached deck by profile id (bypasses the live feed filter
  /// so "Recommencer" still works after everyone was liked).
  Future<bool> _hydrateCachedDeck() async {
    final ids = await UserPrefs.loadDiscoverDeckToday();
    if (ids.isEmpty || !isSupabaseReady) return false;
    try {
      final profiles = await ProfileApi.fetchByIds(ids);
      if (profiles.isEmpty) return false;
      final byId = {for (final p in profiles) p.id: p};
      final ordered = [
        for (final id in ids)
          if (byId[id] != null) byId[id]!,
      ];
      if (ordered.isEmpty) return false;
      if (!mounted) return false;
      setState(() {
        _profiles = ordered;
        _rebuildCards();
      });
      return _cards.isNotEmpty;
    } catch (e) {
      debugPrint('discover: hydrate cache failed: $e');
      return false;
    }
  }

  /// Compte gratuit : les profils du jour sont vus -> écran de fin.
  bool _limitReached = false;
  final List<SeenProfile> _recentSeen = [];

  /// Les personnes vues depuis le dernier chargement du fil.
  final Set<String> _seenHere = {};

  Future<void> _refreshLimit() async {
    final reached = await DailySwipes.reached();
    if (mounted && reached != _limitReached) {
      setState(() => _limitReached = reached);
      if (reached) NavChrome.show();
    }
  }

  List<Friendship> _myFriendships = const [];

  /// Les likes que le cœur vient de changer, avant que la base ait répondu.
  final Map<String, bool> _likeOverride = {};

  /// Retirer un like, même touché avant que son envoi soit terminé.
  late final LikeUndo _likeUndo = LikeUndo(
    (id) => FriendshipApi.retractLike(meId: _myId, friendshipId: id),
  );

  Set<String> get _likedIds {
    final liked = <String>{
      for (final f in _myFriendships)
        if (f.status == 'accepted')
          f.peerOf(_myId)
        else if (f.requester == _myId)
          f.addressee,
    };
    for (final e in _likeOverride.entries) {
      e.value ? liked.add(e.key) : liked.remove(e.key);
    }
    return liked;
  }

  Timer? _pollTimer;
  String _myId = '';

  /// Countries picked on the globe filter bar (world-atlas keys, e.g.
  /// {'France', 'Germany'}), empty for the unfiltered deck. When non-empty the
  /// feed is reloaded filtered to those countries' spoken languages and today's
  /// deck state is NOT persisted (the filtered view is ephemeral).
  Set<String> _countryKeys = {};

  /// Qui je veux rencontrer (page 2 du globe) ; `mixte` = tout le monde.
  GenderFilter _gender = GenderFilter.mixte;
  bool get _filtered => _countryKeys.isNotEmpty;

  // Ring+Arrow transition shown while the globe-filtered feed loads — hidden
  // once BOTH the clip has played through AND the feed has actually landed,
  // so a slow network doesn't cut the animation short.
  bool _showFilterTransition = false;
  // Numéro de la lecture en cours : la clé du clip change à chaque ajout de
  // pays, sinon un 2e appui pendant la lecture ne la rejouait pas (et son
  // `onComplete` ne revenait jamais).
  int _transitionRun = 0;
  bool _transitionAnimDone = false;
  bool _transitionFeedDone = false;

  void _maybeHideFilterTransition() {
    if (_transitionAnimDone && _transitionFeedDone && mounted) {
      setState(() => _showFilterTransition = false);
    }
  }

  List<String> get _filterCountries => _countryKeys
      .map(globeCountryDbName)
      .whereType<String>()
      .toSet()
      .toList();

  /// Opens the spinning-globe country picker (multi-select). A non-empty
  /// result reloads the feed filtered to those countries (the peer's actual
  /// `profiles.country`, not what they speak).
  Future<void> _openGlobe() async {
    final res = await showGeneralDialog<GlobeResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => DiscoverGlobeSheet(
        // Aucun pays présélectionné : le filtre en cours ne se coche pas à la
        // réouverture, on choisit à nouveau.
        initial: const {},
        initialGender: _gender,
      ),
      // Plein écran : apparaît SUR PLACE (fondu + très léger zoom), sans
      // monter du bas.
      transitionBuilder: (_, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1.0)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
          child: child,
        ),
      ),
    );
    if (!mounted || res == null || res.countries.isEmpty) return;
    final keys = res.countries;
    setState(() {
      _countryKeys = keys;
      _gender = res.gender;
    });
    UserPrefs.saveDiscoverGender(res.gender.name);
    Analytics.track('screen_view', props: {
      'screen': 'discover',
      'country_filter': keys.join(','),
      'gender_filter': res.gender.name,
    });
    // Le feed se charge PENDANT le voyage (globe -> escales -> avion), qui
    // remplace l'ancien chargement Lottie ; un appui saute l'animation.
    final load = _loadFeed(countries: _filterCountries);
    // La pub plein ecran part des que l'avion a fini (ou au saut), AVANT la
    // fermeture de l'ecran : on ne voit plus la premiere carte puis la video.
    await playGlobeVoyage(context, keys, onFinishing: _showFilterAd);
    await load;
  }

  /// Full-screen ad when a country filter is applied (a bubble switched ON,
  /// or "Lancer" on the globe), while the filtered feed loads underneath.
  /// Capped (45 s), Pro-exempt and best-effort in AdService — the filter
  /// never waits on it. After an ad actually watched: "how to skip" the first
  /// time, then the "go Premium, no ads" sheet at most once a day.
  void _showFilterAd() {
    unawaited(AdService.showDiscoverInterstitial().then((shown) {
      if (shown && mounted) showAfterAdSheet(context);
    }));
  }

  void _clearCountryFilter() {
    if (_countryKeys.isEmpty) return;
    // Plus aucun pays = plus aucun filtre : le choix homme/femme du globe
    // repart aussi à « mixte » (sinon le deck restait coincé sur un seul
    // genre, et le bouton du globe le gardait coché).
    setState(() {
      _countryKeys = {};
      _gender = GenderFilter.mixte;
      _showFilterTransition = false;
    });
    UserPrefs.saveDiscoverGender(GenderFilter.mixte.name);
    _loadFeed(countries: null);
  }

  /// A bubble of the country row is a filter toggle: it REPLACES the selected
  /// country (one at a time from the row; the globe can still pick several),
  /// or removes it via its ✕. Switched off = back to the whole deck.
  Future<void> _toggleCountry(String key) async {
    HapticFeedback.selectionClick();
    final removing = _countryKeys.contains(key);
    if (removing) {
      final rest = {..._countryKeys}..remove(key);
      if (rest.isEmpty) {
        _clearCountryFilter();
        return;
      }
      setState(() => _countryKeys = rest);
    } else {
      // Un seul pays à la fois depuis la rangée : choisir une bulle remplace la
      // précédente (le globe, lui, reste multi-sélection).
      setState(() => _countryKeys = {key});
      _showFilterAd();
    }
    // The "Go" loader animation only when a country is ADDED — removing one
    // just reloads the deck quietly.
    if (!removing) {
      setState(() {
        _transitionRun++;
        _showFilterTransition = true;
        _transitionAnimDone = false;
        _transitionFeedDone = false;
      });
    }
    Analytics.track('screen_view', props: {
      'screen': 'discover',
      'country_filter': _countryKeys.join(','),
      'source': 'row',
    });
    await _loadFeed(countries: _filterCountries);
    if (!mounted) return;
    _transitionFeedDone = true;
    _maybeHideFilterTransition();
  }

  // ── Écrire depuis une carte ───────────────────────────────────────────────

  Future<bool> _canWrite(RemoteProfile peer) => allowNewContact(
        context,
        meId: _myId,
        peerId: peer.id,
        source: 'discover_feed',
      );

  Future<bool> _sendFromCard(RemoteProfile peer, String body) async {
    try {
      final mine = await ProfileApi.fetchById(_myId);
      final ids = [_myId, peer.id]..sort();
      await ChatApi.sendMessage(
        conversationId: 'dm-${ids[0]}-${ids[1]}',
        senderId: _myId,
        senderName: (mine?.displayName.trim().isNotEmpty ?? false)
            ? mine!.displayName.trim()
            : 'Moi',
        recipientId: peer.id,
        body: body,
        language: (mine?.language.trim().isNotEmpty ?? false)
            ? mine!.language.trim()
            : AppStrings.currentBcp47.value,
        recipientLang: peer.language,
      );
      Analytics.track('message_sent',
          props: {'source': 'discover_feed', 'type': 'text'});
      SwaycoSounds.play(SwSound.msgSent);
      if (!mounted) return true;
      showSentConfirmation(context, AppStrings.t('dm_sent'));
      return true;
    } catch (e) {
      debugPrint('discover: message from card failed: $e');
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return false;
    }
  }

  // ── Le cœur ───────────────────────────────────────────────────────────────

  void _toggleLike(RemoteProfile peer) {
    // Déjà amis : le cœur reste plein.
    if (_friendIds.contains(peer.id)) return;
    if (_likedIds.contains(peer.id)) {
      HapticFeedback.lightImpact();
      SwaycoSounds.play(SwSound.undo);
      setState(() => _likeOverride[peer.id] = false);
      unawaited(_unlike(peer.id));
    } else {
      HapticFeedback.mediumImpact();
      SwaycoSounds.play(SwSound.like);
      setState(() => _likeOverride[peer.id] = true);
      unawaited(_likePeer(peer));
    }
  }

  Future<void> _likePeer(RemoteProfile peer) async {
    final slot = _likeUndo.begin(peer.id);
    try {
      await _likeUndo.turn(peer.id);
      final res = await FriendshipApi.like(
        meId: _myId,
        peerId: peer.id,
        notifyDelay: _kLikePushDelay,
      );
      slot.complete(res.created && !res.matched ? res.friendship?.id : null);
      Analytics.track(
        'friend_request_sent',
        props: {'source': 'discover', 'kind': res.matched ? 'match' : 'like'},
      );
      // Les deux se sont likés : amis, sans écran de célébration ici.
      if (res.matched) MatchCelebration.markShown(peer.id);
      if (!mounted) return;
      // Premier like : « On te prévient dès qu'elle ou il te répond » (une fois).
      if (!res.matched && res.friendship != null) {
        unawaited(NotifEnableFlow.askAfterFirstLike(context));
      }
      await _refreshFriendships();
    } catch (e) {
      if (!slot.isCompleted) slot.complete(null);
      debugPrint('discover: like failed: $e');
      if (!mounted) return;
      setState(() => _likeOverride.remove(peer.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _unlike(String peerId) async {
    try {
      var withdrawn = await _likeUndo.undo(peerId);
      if (withdrawn == null) {
        // Un like d'avant : sa ligne est déjà connue.
        for (final f in _myFriendships) {
          if (f.requester == _myId &&
              f.addressee == peerId &&
              f.status == 'pending') {
            if (await FriendshipApi.retractLike(
                meId: _myId, friendshipId: f.id)) {
              withdrawn = f.id;
            }
          }
        }
      }
      if (!mounted) return;
      await _refreshFriendships();
    } catch (e) {
      debugPrint('discover: unlike failed: $e');
    }
  }

  // ── Fil ───────────────────────────────────────────────────────────────────

  /// Pendant qu'on descend, les pays se rangent et le filtre monte sur la ligne
  /// du logo.
  bool _collapsed = false;
  bool _composing = false;

  void _setCollapsed(bool value) {
    if (value == _collapsed) return;
    void apply() {
      if (mounted && value != _collapsed) setState(() => _collapsed = value);
    }

    // Une correction de défilement peut arriver en pleine mise en page.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _onScrollMoved(ScrollMetrics m, double delta) {
    if (_composing || NavTab.index.value != NavTab.discover) return;
    final y = m.pixels;
    // Le rebond du bas n'est pas un mouvement de la personne.
    if (y <= m.maxScrollExtent) {
      if (y > 40 && delta > 2 && m.maxScrollExtent > 200) {
        _setCollapsed(true);
        NavChrome.hideAuto();
      } else if (y < 20 || delta < -8) {
        _setCollapsed(false);
        NavChrome.show();
      }
    }
    // La barre du bas revient 1,9 s après le dernier mouvement.
    NavChrome.showAfter(const Duration(milliseconds: 1900));
  }

  void _onComposing(bool open) {
    setState(() {
      _composing = open;
      if (open) _collapsed = true;
      if (!open && _scroll.hasClients && _scroll.offset < 20) {
        _collapsed = false;
      }
    });
    open ? NavChrome.hide() : NavChrome.show();
  }

  void _onNavTab() {
    if (NavTab.index.value != NavTab.discover) {
      NavChrome.show();
      VoiceIntroPlayer.stopActive();
    }
  }

  void _onSeen(RemoteProfile p) {
    if (!_seenHere.add(p.id)) return;
    _recentSeen.insert(0, (
      photoUrl: p.discoverPhotoUrl.isNotEmpty
          ? p.discoverPhotoUrl
          : (p.photos.isNotEmpty ? p.photos.first : null),
      country: p.country,
    ));
    if (_recentSeen.length > 3) _recentSeen.removeLast();
    unawaited(DailySwipes.markSeen(p.id).then((_) => _refreshLimit()));
    if (!_filtered &&
        _cards.isNotEmpty &&
        _cards.every((c) => _seenHere.contains(c.profile.id))) {
      UserPrefs.markDiscoverDoneToday();
      unawaited(_scheduleSwipesBack());
    }
  }

  /// Quota gratuit épuisé : une notification quand les profils reviennent
  /// (demain 9 h, heure locale). Le Pro n'a pas de limite, donc pas de rappel.
  Future<void> _scheduleSwipesBack() async {
    try {
      final me = await ProfileApi.fetchById(_myId);
      if (me != null && (me.isPro || me.isPlus)) return;
      final now = DateTime.now();
      final next = DateTime(now.year, now.month, now.day + 1, 9);
      await LocalNotifications.scheduleSwipesBackReminder(
        title: AppStrings.t('swipes_back_title'),
        body: AppStrings.t('swipes_back_body'),
        after: next.difference(now),
      );
    } catch (_) {
      // Un rappel de confort.
    }
  }

  // Une carte publicitaire toutes les 2 à 6 cartes (retiré au sort après
  // chacune, pour que le rythme ne se devine pas). Pro : deux fois plus espacée.
  static final Random _adRng = Random();
  static int _nextAdGap() =>
      (_adRng.nextInt(5) + 2) * (RevenueCat.proActive.value ? 2 : 1);

  Future<void> _openProfile(RemoteProfile p) async {
    FocusManager.instance.primaryFocus?.unfocus();
    VoiceIntroPlayer.stopActive();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => ProfileScreen(userId: p.id)),
    );
    if (!mounted) return;
    if (!_composing) NavChrome.show();
    _likeOverride.remove(p.id);
    await _refreshFriendships();
  }

  void _openPhotos(
    ({RemoteProfile profile, List<String> photos}) card,
    int index,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();
    showPhotoViewer(
      context,
      photos: card.photos,
      index: index,
      viewerMode: true,
      footerProfile: card.profile,
    );
  }

  /// Reloads the Discover feed, optionally filtered by peer [countries].
  Future<void> _loadFeed({required List<String>? countries}) async {
    if (_myId.isEmpty || !isSupabaseReady) return;
    setState(() {
      _feedLoading = true;
      _collapsed = false;
      _composing = false;
      _seenHere.clear();
    });
    NavChrome.show();
    try {
      final feed = await ProfileApi.fetchDiscoverFeed(
        myId: _myId,
        countries: countries,
      ).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _profiles = feed;
        _rebuildCards();
        _feedLoading = false;
        _loadFailed = _cards.isEmpty && ProfileApi.lastDiscoverFeedFailed;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _precacheFirst();
      });
    } catch (e) {
      debugPrint('discover: _loadFeed(countries=$countries) failed: $e');
      if (mounted) {
        setState(() {
          _feedLoading = false;
          _loadFailed = _cards.isEmpty;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    Analytics.track('screen_view', props: {'screen': 'discover'});
    // Le genre choisi la derniere fois : applique au deck des qu'il est lu.
    UserPrefs.loadDiscoverGender().then((v) {
      final g = GenderFilter.values.asNameMap()[v] ?? GenderFilter.mixte;
      if (!mounted || g == _gender) return;
      setState(() {
        _gender = g;
        _rebuildCards();
      });
    });
    _bootstrap();
    unawaited(_refreshLimit());
    // Devenir Pro (depuis le paywall) rouvre Discover sans recharger l'app.
    RevenueCat.proActive.addListener(_refreshLimit);
    NavTab.index.addListener(_onNavTab);
    _pollTimer = WebPoll.every(const Duration(seconds: 12), _refreshFriendships);
    MatchCelebration.matchesChanged.addListener(_refreshFriendships);
    // Warm up the "Discover" interstitial (shown when a country bubble is
    // switched on) and the rewarded video (Likes unlock) in the background.
    // No-ops for Pro subscribers and never blocks/throws on failure.
    unawaited(AdService.preload());
    unawaited(RewardedVideo.preload());
  }

  @override
  void dispose() {
    NavChrome.show();
    _pollTimer?.cancel();
    MatchCelebration.matchesChanged.removeListener(_refreshFriendships);
    RevenueCat.proActive.removeListener(_refreshLimit);
    NavTab.index.removeListener(_onNavTab);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refreshFriendships() async {
    if (_myId.isEmpty || !isSupabaseReady) return;
    try {
      final mine = await FriendshipApi.fetchMine(_myId);
      if (!mounted) return;
      setState(() {
        _myFriendships = mine;
        // La base dit désormais ce que le cœur avait annoncé.
        final stored = {
          for (final f in mine)
            if (f.status == 'accepted')
              f.peerOf(_myId)
            else if (f.requester == _myId)
              f.addressee,
        };
        _likeOverride.removeWhere((id, liked) => stored.contains(id) == liked);
      });
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    final id = await DeviceId.getOrCreate();
    if (!mounted) return;
    setState(() => _myId = id);
    if (!isSupabaseReady || id.isEmpty) {
      setState(() => _feedLoading = false);
      AppBoot.markHomeReady();
      return;
    }
    try {
      final results = await Future.wait(<Future<Object>>[
        FriendshipApi.fetchMine(id),
        ProfileApi.fetchDiscoverFeed(myId: id),
        UserPrefs.loadDiscoverDoneToday(),
      ]).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      final friendships = results[0] as List<Friendship>;
      final feed = results[1] as List<RemoteProfile>;
      final doneToday = results[2] as bool;

      // Nouveau paquet du jour : le rappel de retour a fait son travail.
      if (!doneToday) unawaited(LocalNotifications.cancelSwipesBackReminder());
      setState(() {
        _myFriendships = friendships;
        _profiles = feed;
        _rebuildCards();
      });

      // Live feed empty (everyone already liked) but we still have today's
      // deck cached → restore it.
      if (_cards.isEmpty) {
        final ok = await _hydrateCachedDeck();
        debugPrint('discover: feed empty, cache hydrate=$ok');
      }

      if (!mounted) return;
      setState(() {
        _feedLoading = false;
        _loadFailed = _cards.isEmpty && ProfileApi.lastDiscoverFeedFailed;
      });
      debugPrint('discover: feed=${feed.length} cards=${_cards.length}');
      AppBoot.markHomeReady();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _precacheFirst();
      });
    } catch (e) {
      debugPrint('discover: bootstrap failed: $e');
      // Last resort: show today's cached deck if the network timed out.
      await _hydrateCachedDeck();
      if (mounted) {
        setState(() {
          _feedLoading = false;
          _loadFailed = _cards.isEmpty;
        });
      }
      AppBoot.markHomeReady();
    }
  }

  void _precacheFirst() {
    if (!mounted) return;
    for (final c in _cards.take(6)) {
      precacheImage(NetworkImage(c.photos.first), context).ignore();
    }
  }

  /// Bas du fil : remonter en haut.
  void _backToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
    );
    _setCollapsed(false);
  }

  /// Empty-state Restart. A live refetch alone often returns [] once everyone
  /// is liked, hence the cached deck as a fallback.
  Future<void> _reset() async {
    if (_myId.isEmpty) return;
    await UserPrefs.clearDiscoverDone();
    await _loadFeed(countries: null);
    if (mounted && _cards.isEmpty) await _hydrateCachedDeck();
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final collapsed = _collapsed;
    // La ligne du logo, avec un peu d'air : sans barre d'état (web) le filtre
    // rangé touchait le bord et était coupé.
    final headTop = math.max(safeTop + 4, 12.0);
    final rowTop = headTop + _DiscoverHeader.height;
    final listTop = collapsed ? headTop + 47 : rowTop + _CountryRow.height;
    final filterSize = collapsed ? 40.0 : 60.0;
    final bottomSpace = math.max(
      130.0,
      GlassNavBar.totalReservedHeight + safeBottom + 24,
    );
    final still = MediaQuery.disableAnimationsOf(context);
    final move = still ? Duration.zero : const Duration(milliseconds: 400);
    const curve = Cubic(0.3, 0.8, 0.3, 1);

    final Widget body;
    if (_feedLoading) {
      body = Center(
        child: CircularProgressIndicator(color: SC.fg, strokeWidth: 2),
      );
    } else if (_limitReached) {
      body = Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomSpace - 24),
        child: DailyLimitView(
          seen: _recentSeen.isNotEmpty
              ? List.of(_recentSeen)
              : [
                  for (final c in _cards.take(3))
                    (
                      photoUrl: c.photos.isNotEmpty ? c.photos.first : null,
                      country: c.profile.country,
                    ),
                ],
          onReset: () => setState(() => _limitReached = false),
        ),
      );
    } else if (_loadFailed && _cards.isEmpty) {
      body = LoadFailedView(onRetry: _retryLoad);
    } else if (_cards.isEmpty) {
      body = _Empty(
        onReset: _filtered ? _clearCountryFilter : _reset,
        onChooseCountries: _openGlobe,
        body: _filtered ? AppStrings.t('globe_filter_empty') : null,
      );
    } else {
      body = DiscoverFeed(
        controller: _scroll,
        entries: _cards,
        likedIds: _likedIds,
        onToggleLike: _toggleLike,
        onOpenProfile: _openProfile,
        onOpenPhotos: _openPhotos,
        canWrite: _canWrite,
        onSend: _sendFromCard,
        onSeen: _onSeen,
        onScrollMoved: _onScrollMoved,
        onComposing: _onComposing,
        nextAdGap: _nextAdGap,
        footer: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: _DiscoverDone(onRestart: _backToTop),
        ),
        bottomSpace: bottomSpace,
      );
    }

    return Scaffold(
      backgroundColor: SC.tabBg,
      extendBody: true,
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: SC.classic ? SC.bg : null,
          gradient: SC.classic
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: SC.light
                      ? const [
                          Color(0xFFCFE0FF),
                          Color(0xFFE4EDFF),
                          Color(0xFFF3F4F8),
                        ]
                      : const [
                          Color(0xFF12306B),
                          Color(0xFF0A1633),
                          Color(0xFF070D1F),
                        ],
                  stops: const [0, 0.2, 0.45],
                ),
        ),
        child: Stack(
          children: [
            // ── Logo + Pro ────────────────────────────────────────────────
            Positioned(
              top: headTop,
              left: 0,
              right: 0,
              child: const _DiscoverHeader(),
            ),

            // ── Le fil (ou l'écran d'attente / de fin) ────────────────────
            AnimatedPositioned(
              duration: move,
              curve: curve,
              top: listTop,
              left: 0,
              right: 0,
              bottom: 0,
              child: body,
            ),

            // ── Les pays ──────────────────────────────────────────────────
            AnimatedPositioned(
              duration: move,
              curve: curve,
              top: collapsed ? rowTop - 24 : rowTop,
              left: 0,
              right: 0,
              height: _CountryRow.height,
              child: IgnorePointer(
                ignoring: collapsed,
                child: AnimatedOpacity(
                  opacity: collapsed ? 0 : 1,
                  duration:
                      still ? Duration.zero : const Duration(milliseconds: 300),
                  child: _CountryRow(
                    selected: _countryKeys,
                    onCountry: _toggleCountry,
                  ),
                ),
              ),
            ),

            // ── Le filtre (le globe) ──────────────────────────────────────
            AnimatedPositioned(
              duration: move,
              curve: curve,
              top: collapsed ? headTop - 3 : rowTop + 6,
              left: 20,
              width: filterSize,
              height: filterSize,
              child: _FilterButton(collapsed: collapsed, onTap: _openGlobe),
            ),

            // ── Transition "Go" du filtre globe — icône Ring+Arrow (SANS
            //    wordmark, contrairement au splash de boot) + un "Chargement"
            //    séparé. ───────────────────────────────────────────────────
            if (_showFilterTransition)
              Positioned.fill(
                child: Stack(
                  children: [
                    LottieIconTransition(
                      key: ValueKey(_transitionRun),
                      asset: 'assets/discover_filter_transition.json',
                      onComplete: () {
                        _transitionAnimDone = true;
                        _maybeHideFilterTransition();
                      },
                    ),
                    Align(
                      alignment: const Alignment(0, 0.6),
                      child: Text(
                        AppStrings.t('profile_loading'),
                        style: TextStyle(
                          color: SC.fg,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Le bouton « filtre » : 60 px à gauche des pays, 40 px sur la ligne du logo
/// quand le fil est descendu. Il ouvre le globe.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.collapsed, required this.onTap});

  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Semantics(
      button: true,
      label: AppStrings.t('globe_filter_cta'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: light ? const Color(0xFFF8F9FC) : const Color(0xFF0D1A3A),
            border: Border.all(color: const Color(0xFF2B8CFF), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x592B7FFF),
                blurRadius: 12,
                spreadRadius: -4,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Center(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 400),
              child: Icon(
                Icons.tune_rounded,
                size: collapsed ? 22 : 30,
                color: light ? const Color(0xFF04123A) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Header — le logo swaycø, seul (handoff 3c : pas de loupe)
// ══════════════════════════════════════════════════════════════════════════════

class _DiscoverHeader extends StatelessWidget {
  const _DiscoverHeader();

  /// Hauteur sous la safe area. Resserrée (52 → 43) pour que l'écart logo →
  /// bulles pays soit le même (≈ 16) que bulles pays → carte et carte →
  /// boutons ; le logo, lui, garde sa place (voir le padding du build).
  static const double height = 43.0;

  /// Le logo d'origine, taille et place d'origine, centré horizontalement
  /// dans la bande. (Le SVG du handoff a été retiré à la demande.)
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Centre à 20 px du haut de la bande, comme avant le resserrement
            // (43 − 3 = 40 de zone utile).
            // Le texte garde 40 px de haut (sinon le bas du « y » est rogne) ;
            // la remontee de 8 px se fait par translation, sans toucher a la place.
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 3),
              child: Transform.translate(
                offset: const Offset(0, -8),
                child: const SwaycoWordmark(adaptive: true),
              ),
            ),
            // En haut à droite : le bouton Pro, même lien que Réglages >
            // Mon abonnement (le paywall).
            Positioned(
              right: 0,
              // Centre un peu sous celui de la boite du logo : les minuscules de
              // « swaycø » pesent vers le bas, le bouton s'aligne sur leur milieu.
              top: 2,
              child: PadTap(
                behavior: HitTestBehavior.opaque,
                onTap: () => showPaywallSheet(context, source: 'discover_bar'),
                child: Sparkles(
                  child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [SC.brandBlue, SC.brandCyan],
                    ),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: SC.brandBlue.withValues(alpha: 0.45),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.workspace_premium_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      SizedBox(width: 5),
                      Text(
                        'Pro',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
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

// ══════════════════════════════════════════════════════════════════════════════
// Rangée de pays — « Filtrer » (le globe) + tous les pays du globe, en filtres
// ══════════════════════════════════════════════════════════════════════════════

/// La rangée, à droite du bouton filtre : TOUS les pays du globe
/// ([kGlobeCountries]) dans une bande qui défile. Chaque bulle est un filtre
/// qu'on allume / éteint ; plusieurs peuvent l'être à la fois.
///
/// Ordre : les pays sélectionnés d'abord, le DERNIER choisi en tête (on voit
/// tout de suite ce qu'on vient d'allumer), puis les autres dans l'ordre du
/// globe. La bande revient au début à chaque changement.
/// Diamètre des bulles de la rangée (sans libellé dessous : plus grandes).
const double _kBubble = 60.0;

class _CountryRow extends StatefulWidget {
  const _CountryRow({
    required this.selected,
    required this.onCountry,
  });

  /// Pays sélectionnés, dans l'ordre où ils l'ont été (Set à insertion
  /// ordonnée : le dernier ajouté est le dernier de l'itération).
  final Set<String> selected;
  final ValueChanged<String> onCountry;

  /// 6 dessus (le retrait des bulles) + bulle + 14 pour le compteur dessous.
  static const double height = 6 + _kBubble + 14;

  @override
  State<_CountryRow> createState() => _CountryRowState();
}

class _CountryRowState extends State<_CountryRow> {
  final _scroll = ScrollController();

  /// Les pays dans l'ordre de leur DERNIER TOUCHER (choix ou retrait), le plus
  /// récent en tête. Un pays décoché reste donc en tête — là où on vient de le
  /// toucher — au lieu de retomber à sa place d'origine. Les pays jamais
  /// touchés suivent, dans l'ordre normal.
  late List<String> _recent = [
    ...widget.selected.where(kGlobeCountries.containsKey).toList().reversed,
  ];

  @override
  void initState() {
    super.initState();
    // Les nombres des puces sont ceux du globe : même chargement, même source
    // (vue country_counts, ou le décompte local). Rien ne s'affiche avant.
    GlobePlaces.load({
      for (final e in kGlobeCountries.entries) e.value.dbName: e.key,
    }).then((_) {
      if (mounted) setState(() {});
    });
  }

  int _countOf(String key) => GlobePlaces.country(key)?.count ?? 0;

  /// Le pays sous le doigt (appui) ou sous la souris (survol). Tant qu'il y en
  /// a un, TOUS les compteurs de la rangée sont visibles.
  String? _peek;

  void _setPeek(String key, bool on) {
    if (on) {
      if (_peek == key) return;
      setState(() => _peek = key);
    } else if (_peek == key) {
      setState(() => _peek = null);
    }
  }

  String _format(int n) => formatCount(
        n,
        Locale(AppStrings.currentBcp47.value.split(RegExp('[-_]')).first),
      );

  String _countLabel(int n) =>
      AppStrings.t('country_profiles_count', args: {'n': '$n'});

  void _touch(Iterable<String> keys) {
    for (final k in keys) {
      if (!kGlobeCountries.containsKey(k)) continue;
      _recent.remove(k);
      _recent.insert(0, k);
    }
  }

  @override
  void didUpdateWidget(_CountryRow old) {
    super.didUpdateWidget(old);
    // Ajoutés d'abord (dans l'ordre où ils ont été choisis), puis retirés : le
    // dernier pays touché passe en première position, choisi ou décoché.
    _touch(widget.selected.where((k) => !old.selected.contains(k)));
    _touch(old.selected.where((k) => !widget.selected.contains(k)));
    // Une sélection vient de changer : le pays choisi est passé en tête —
    // on y ramène la bande pour qu'il reste sous les yeux.
    if (old.selected.length != widget.selected.length ||
        !old.selected.containsAll(widget.selected)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// En dessous de ce nombre de comptes, un pays passe au fond de la rangée.
  static const _kMinCountryCount = 15;

  List<String> get _orderedKeys {
    final rest = [
      for (final k in kGlobeCountries.keys)
        if (!_recent.contains(k)) k,
    ];
    return [
      ..._recent,
      for (final k in rest)
        if (_countOf(k) >= _kMinCountryCount) k,
      for (final k in rest)
        if (_countOf(k) < _kMinCountryCount) k,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final keys = _orderedKeys;
    return SizedBox(
      height: _CountryRow.height,
      child: ListView.separated(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              // La place du bouton filtre, posé par-dessus à gauche.
              padding: const EdgeInsets.fromLTRB(92, 6, 20, 0),
              itemCount: keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) {
                final key = keys[i];
                final code = kGlobeCountries[key]!.code;
                final on = widget.selected.contains(key);
                // Liseré de verre (blanc 20 %) d'1 px : juste de quoi détacher
                // la bulle du fond, choisie ou non ; c'est « Filtrer » qui porte
                // l'anneau en dégradé.
                // Choisie : l'anneau passe au bleu de la marque (2 px).
                final circle = Container(
                    width: _kBubble,
                    height: _kBubble,
                    padding: EdgeInsets.all(on ? 2 : 1),
                    decoration: BoxDecoration(
                      color: on
                          ? null
                          : (SC.light
                              ? const Color(0x2404123A)
                              : SC.glassBorderStrong),
                      gradient: on ? SC.brandGradient : null,
                      shape: BoxShape.circle,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: _kSurface,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      // La silhouette remplit le rond et c'est la BULLE qui la
                      // rogne : elle en fait partie, pas posée dessus.
                      clipBehavior: Clip.antiAlias,
                      child: CountrySilhouette(
                        geoName: key,
                        iso2: code,
                        size: 44,
                      ),
                    ),
                  );
                return _RowItem(
                  // La clé suit le pays, pas sa place : quand l'ordre
                  // change, chaque bulle garde sa silhouette déjà chargée.
                  key: ValueKey(key),
                  label: _countOf(key) > 0
                      ? '${AppStrings.t('country_$code')}, '
                          '${_countLabel(_countOf(key))}'
                      : AppStrings.t('country_$code'),
                  // Un tap CHOISIT ce pays (et retire le précédent). Retirer
                  // passe par la petite croix, jamais par un tap sur la bulle.
                  onTap: () {
                    if (!on) widget.onCountry(key);
                  },
                  onPeek: (v) => _setPeek(key, v),
                  bubble: SizedBox(
                    width: _kBubble,
                    height: _kBubble,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        circle,
                        // Compteur : centré sous le rond, 8 px en dessous ; il
                        // reste dans la respiration de _CountryRow.height.
                        Positioned(
                          // Ancré sur le rond (la case, elle, prend toute la
                          // hauteur de la liste) : presque entièrement SOUS
                          // la bulle, 11 px en dessous (la silhouette ne laisse
                          // que 5,5 px de marge au bas du rond).
                          left: 0,
                          width: _kBubble,
                          top: _kBubble + 11 - 17,
                          height: 17,
                          child: IgnorePointer(
                            child: Center(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 150),
                                // Doigt ou souris sur UNE bulle : tous les compteurs
                                // s'affichent ensemble.
                                child: _peek != null && _countOf(key) > 0
                                    ? _CountCapsule(
                                        key: const ValueKey('count'),
                                        text: _format(_countOf(key)),
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey('none'),
                                      ),
                              ),
                            ),
                          ),
                        ),
                        if (on)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => widget.onCountry(key),
                              child: Semantics(
                                button: true,
                                label: AppStrings.t('cancel'),
                                // Zone de tap 40, dessin 17 dans le coin : un tap
                                // sur une bulle déjà choisie ne fait rien d'autre,
                                // donc la zone peut mordre largement sur le rond.
                                child: SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: Align(
                                    alignment: Alignment.topRight,
                                    child: Container(
                                      width: 17,
                                      height: 17,
                                      decoration: BoxDecoration(
                                        color: _kSurface,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: SC.accent,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: Icon(
                                        Icons.close_rounded,
                                        color: SC.accentFg,
                                        size: 11,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Le nombre de profils d'un pays, sous sa bulle (design C). Blanc sur bleu
/// nuit, liseré de la couleur du fond pour la détacher du rond. Aucun point
/// d'état : ce sont des profils, pas des gens en ligne.
class _CountCapsule extends StatelessWidget {
  const _CountCapsule({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    // Jamais plus large que la bulle (50), 6 px entre deux bulles.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kBubble),
      child: Container(
        height: 17,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1B2A55),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: SC.bgDeep, width: 1.5),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_rounded, size: 10, color: Colors.white),
              const SizedBox(width: 2),
              Text(
                text,
                maxLines: 1,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowItem extends StatelessWidget {
  const _RowItem({
    super.key,
    required this.bubble,
    required this.label,
    required this.onTap,
    this.onPeek,
  });

  final Widget bubble;
  final String label;
  final VoidCallback onTap;

  /// Appelé avec true quand un doigt appuie ou que la souris survole la case,
  /// false quand il la quitte. Null : la case n'a pas de compteur à montrer.
  final ValueChanged<bool>? onPeek;

  @override
  Widget build(BuildContext context) {
    // Plus aucun nom sous les bulles, même choisies : la silhouette parle
    // d'elle-même et la croix jaune dit ce qui filtre. Le nom reste lu par
    // le lecteur d'écran.
    final item = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 60,
        child: Semantics(label: label, button: true, child: bubble),
      ),
    );
    final peek = onPeek;
    if (peek == null) return item;
    // Listener (et non un geste) : il ne joue pas dans l'arène, donc ni le tap
    // ni le défilement de la rangée ne changent.
    return MouseRegion(
      onEnter: (_) => peek(true),
      onExit: (_) => peek(false),
      child: Listener(
        onPointerDown: (_) => peek(true),
        onPointerUp: (_) => peek(false),
        onPointerCancel: (_) => peek(false),
        child: item,
      ),
    );
  }
}

/// Le panneau que la carte déplie : un PASSEPORT. Il monte fermé (une couverture
/// au dégradé de marque le recouvre), la couverture s'ouvre sur sa charnière
/// gauche, puis les pages se remplissent bloc après bloc et le tampon du pays
/// vient frapper. Il reste DANS la carte et se rabat d'un glissement vers le
/// bas. À la fermeture : aucune mise en scène, tout disparaît.
class ProfileInfoPanel extends StatefulWidget {
  const ProfileInfoPanel({
    super.key,
    required this.profile,
    required this.onClose,
    required this.open,
    this.hideFlag = false,
    this.bandInsetRight = 0,
    this.animateOnMount = false,
    this.bottomPadding = 96,
    this.alwaysScrollable = true,
    this.onContentHeight,
    this.fillFreeSpace = true,
  });

  /// Sans bio, la carte d'infos s'étire pour remplir la place libre du panneau.
  /// Faux dans la visionneuse du profil d'un pair : étirer ne sert à rien chez
  /// quelqu'un qui n'a presque rien.
  final bool fillFreeSpace;

  /// Hauteur dont le panneau a besoin pour montrer tout son contenu sans
  /// défiler (chrome compris). La visionneuse s'en sert pour n'agrandir le
  /// passeport que s'il y a beaucoup à afficher.
  final ValueChanged<double>? onContentHeight;

  /// Joue la mise en scène du Discover (couverture qui s'ouvre, blocs qui
  /// apparaissent, tampon) dès que le panneau est monté, même s'il est déjà
  /// `open` : le passeport du profil d'un pair.
  final bool animateOnMount;

  /// Marge sous le contenu : 96 sur la carte (la place des boutons ✕ / ❤), moins
  /// dans la visionneuse qui n'en a pas.
  final double bottomPadding;

  /// Faux : le contenu ne défile que s'il dépasse (le passeport du profil d'un
  /// pair est assez haut pour tenir sans défiler).
  final bool alwaysScrollable;

  /// Place laissée libre à droite du bandeau « SWAYCØ · PASSEPORT » (la
  /// visionneuse y pose son bouton ✕).
  final double bandInsetRight;

  final RemoteProfile profile;

  /// Vrai quand le panneau est déplié : c'est ce qui déclenche le passeport.
  final bool open;

  /// Aperçu de MA carte : pas de drapeau (on voit celui des autres, pas le sien).
  final bool hideFlag;
  final VoidCallback onClose;

  @override
  State<ProfileInfoPanel> createState() => _ProfileInfoPanelState();
}

/// Coins du passeport : 28 en haut, ceux de la carte en bas — le panneau
/// epouse le cadre au lieu de laisser deborder des angles carres.
const BorderRadius _kPassportRadius = BorderRadius.only(
  topLeft: Radius.circular(28),
  topRight: Radius.circular(28),
  bottomLeft: Radius.circular(_kCardRadius),
  bottomRight: Radius.circular(_kCardRadius),
);

class _ProfileInfoPanelState extends State<ProfileInfoPanel>
    with SingleTickerProviderStateMixin {
  /// Toute la mise en scène sur UN contrôleur : couverture à 350 ms (950 ms de
  /// rotation), blocs de 550 ms à 1,65 s, tampon à 1,5 s.
  static const int _totalMs = 2000;
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _totalMs),
  );

  /// Distance parcourue vers le bas depuis le début du geste. Fermer sur le
  /// seul élan demandait un coup sec : un glissement lent, celui qu'on fait
  /// quand on croit scroller, mourait à zéro de vélocité et le panneau
  /// restait planté là.
  double _dragDy = 0;

  final GlobalKey _contentKey = GlobalKey();
  double _lastReported = 0;

  /// Mesure le contenu (hauteur naturelle de la colonne) après chaque image et
  /// rapporte la hauteur totale nécessaire : poignée + bandeau + marges + contenu.
  void _reportContentHeight() {
    final cb = widget.onContentHeight;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final h = _contentKey.currentContext?.size?.height;
      if (h == null) return;
      // 22 (poignée) + 30 (bandeau) + 14 (marge haute) + marge basse.
      final needed = h + 22 + 30 + 14 + widget.bottomPadding;
      if ((needed - _lastReported).abs() > 1) {
        _lastReported = needed;
        cb(needed);
      }
    });
  }

  /// Vrai depuis l'instant où le débord a demandé la fermeture jusqu'au retour
  /// de la liste à sa position haute : sans lui, chaque image du geste
  /// rappellerait onClose.
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    if (widget.open) {
      if (widget.animateOnMount) {
        // Après la 1re image : l'animation ne démarre pas pendant la
        // transition d'ouverture de la visionneuse.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (MediaQuery.disableAnimationsOf(context)) {
            _ctl.value = 1;
          } else {
            _ctl.forward(from: 0);
          }
        });
      } else {
        _ctl.value = 1;
      }
    }
  }

  @override
  void didUpdateWidget(ProfileInfoPanel old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _ctl.value = 1;
      } else {
        _ctl.forward(from: 0);
      }
    } else if (!widget.open && old.open) {
      // Fermeture : pas de couverture, tout est deja ouvert pendant que le
      // panneau redescend ; on remet a zero une fois hors ecran.
      _ctl.value = 1;
      Future<void>.delayed(const Duration(milliseconds: 320), () {
        if (mounted && !widget.open) _ctl.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// Le débord vers le haut vaut fermeture. [ScrollUpdateNotification] porte
  /// des pixels négatifs quand la liste est tirée sous son point de départ —
  /// c'est là, et seulement là, que le glissement cesse d'être du défilement.
  bool _onPanelScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final over = n.metrics.pixels;
      if (over >= 0) {
        _dismissing = false;
      } else if (!_dismissing && over < -70) {
        _dismissing = true;
        widget.onClose();
      }
    }
    return false;
  }

  /// Animation d'un bloc : opacité 0→1 et translation 10→0 sur 450 ms, à partir
  /// de [startMs].
  Animation<double> _at(int startMs, [int durMs = 450]) => _ctl.drive(
        CurveTween(
          curve: Interval(
            startMs / _totalMs,
            (startMs + durMs) / _totalMs,
            curve: Curves.easeOut,
          ),
        ),
      );

  Widget _reveal(int startMs, Widget child) {
    final a = _at(startMs);
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        builder: (_, c) =>
            Transform.translate(offset: Offset(0, 10 * (1 - a.value)), child: c),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => _panel(context, c.maxHeight),
      );

  Widget _panel(BuildContext context, double panelHeight) {
    _reportContentHeight();
    final p = widget.profile;
    // Couleur du persona : halo du bas et bord haut du passeport.
    final accent =
        kPersonaColors[personaCategoryByLabel(p.personaCategory)?.label ?? ''] ??
            SC.brandCyan;
    final passNo = p.id.length >= 4
        ? p.id.substring(p.id.length - 4).toUpperCase()
        : '0001';

    // Les blocs, dans l'ordre d'apparition (550 / 650 / 700 / 800 / … ms).
    var step = 0;
    const starts = [550, 650, 700, 800, 900, 1000, 1100, 1200];
    int next() => starts[math.min(step++, starts.length - 1)];

    final content = <Widget>[
      _reveal(next(), _PanelHeader(profile: p, hideFlag: widget.hideFlag)),
      const SizedBox(height: 14),
      if (p.bio.trim().isNotEmpty) ...[
        _reveal(
          next(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                AppStrings.t('profile_bio_section').toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: bentoLabelStyle(),
              ),
              const SizedBox(height: 6),
              TranslatedProfileText(
                text: p.bio.trim(),
                profileId: p.id,
                field: 'bio',
                fromLang: p.language,
                showNote: true,
                style: TextStyle(
                  color: SC.light
                      ? const Color(0xB804123A)
                      : const Color(0xCCFFFFFF),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ] else
        // Le rang du bio est consomme meme sans bio : les delais restent ceux
        // de la maquette.
        const SizedBox.shrink(),
      _reveal(
        next(),
        ProfileInfoCard(
          profile: p,
          showHeader: false,
          framed: false,
          signReveal: _at(1000, 700),
          // Sans bio, la carte prend la place libre : poignée, bandeau, marges
          // et en-tête (~226) retirés de la hauteur du panneau.
          fillHeight: widget.fillFreeSpace && p.bio.trim().isEmpty
              ? math.max(0.0, panelHeight - 226)
              : null,
          interestsBody: p.interests.isEmpty
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '$kFactEmojiInterests ${AppStrings.t('profile_interests_section').toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: bentoLabelStyle(),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in p.interests)
                          InterestPill(
                            label: interestPillText(tag),
                            prominent: true,
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Un glissement vers le bas suffit à le rabattre — pas de bouton. Un
      // coup sec OU 56 px parcourus : les deux ferment.
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 120 || _dragDy > 56) widget.onClose();
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ── La page intérieure ──────────────────────────────────────────
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: SC.light ? Colors.white : const Color(0xFF161B2E),
                borderRadius: _kPassportRadius,
                border: Border(
                  top: BorderSide(
                    color: accent.withValues(alpha: 0.6),
                    width: 1.2,
                  ),
                ),
              ),
              child: ClipRRect(
                borderRadius: _kPassportRadius,
                child: Stack(
                  children: [
                    // Halo de la couleur du persona, DANS le cadre : transparent en
                    // haut, 70 % d'opacité sur le bord bas, sur 62 % de la hauteur.
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        widthFactor: 1,
                        heightFactor: 0.62,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  accent.withValues(alpha: 0.70),
                                  accent.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // La poignée : elle dit "tire-moi vers le bas".
                        Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 8),
                          child: Center(
                            child: Container(
                              width: 44,
                              height: 4,
                              decoration: BoxDecoration(
                                color: SC.light
                                    ? const Color(0x471F5EFF)
                                    : const Color(0x38FFFFFF),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                        ),
                        // Bandeau « SWAYCØ · PASSEPORT ».
                        Container(
                          height: 30,
                          padding: EdgeInsets.fromLTRB(
                              20, 0, 20 + widget.bandInsetRight, 0),
                          decoration:
                              const BoxDecoration(gradient: SC.brandGradient),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  AppStrings.t('passport_band'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.ibmPlexMono(
                                    fontSize: 11,
                                    letterSpacing: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.public_rounded,
                                size: 17,
                                color: SC.accent,
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          // Le contenu défile. Et comme un défilement s'approprie
                          // tout glissement vertical, c'est LUI qui porte la
                          // fermeture : tiré vers le bas alors qu'on est déjà en
                          // haut de la liste, le geste n'est plus du défilement,
                          // c'est un « referme-moi » (70 px de débord suffisent).
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _onPanelScroll,
                            child: SingleChildScrollView(
                              physics: BouncingScrollPhysics(
                                parent: widget.alwaysScrollable
                                    ? const AlwaysScrollableScrollPhysics()
                                    : null,
                              ),
                              padding: EdgeInsets.fromLTRB(
                                  20, 14, 20, widget.bottomPadding),
                              child: Column(
                                key: _contentKey,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: content,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Tant que la couverture est fermée, la page est assombrie.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: FadeTransition(
                          opacity: ReverseAnimation(_at(300, 800)),
                          child: const ColoredBox(color: Color(0x73000000)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── La couverture ───────────────────────────────────────────────
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctl,
                builder: (_, _) {
                  final ms = _ctl.value * _totalMs;
                  final open = ((ms - 350) / 950).clamp(0.0, 1.0);
                  final t = const Cubic(0.65, 0.05, 0.25, 1).transform(open);
                  // Face arrière masquée au-delà de la mi-course ; fondu entre
                  // 600 et 1000 ms.
                  if (t > 0.5 || ms >= 1000) return const SizedBox.shrink();
                  final fade = ms <= 600 ? 1.0 : 1 - (ms - 600) / 400;
                  return Opacity(
                    opacity: fade.clamp(0.0, 1.0),
                    child: Transform(
                      // Comme un livre : charniere a gauche (le dos), le bord droit
                      // se leve VERS NOUS et part vers la gauche.
                      alignment: Alignment.centerLeft,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0007)
                        ..rotateY(115 * math.pi / 180 * t),
                      child: _PassportCover(
                        passNo: passNo,
                        title: AppStrings.t('passport_title'),
                        sub: AppStrings.t('passport_sub'),
                        // Carte de Découvrir : 100 (boutons flottants). Dans la
                        // visionneuse (marge basse réduite) : le texte se pose
                        // au bas du cadre, et la pastille évite le ✕.
                        bottomInset: widget.bottomPadding + 4,
                        rightInset: widget.bandInsetRight,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Couverture 11b : dégradé de marque, symbole de l'app en filigrane, pastille
/// jaune avec un globe, et en bas à gauche le numéro, « Passeport » et sa ligne.
class _PassportCover extends StatelessWidget {
  const _PassportCover({
    required this.passNo,
    required this.title,
    required this.sub,
    this.bottomInset = 100,
    this.rightInset = 0,
  });

  /// Distance du bloc de texte au bas du cadre : 100 sur la carte (au-dessus des
  /// boutons ✕ / ❤ flottants), beaucoup moins dans la visionneuse qui n'en a pas.
  final double bottomInset;

  /// Place réservée à droite en haut (le ✕ de la visionneuse) : la pastille
  /// globe se décale pour ne pas passer dessous.
  final double rightInset;

  final String passNo;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
    // Le filigrane suit la LARGEUR du cadre (≈ 400 px sur une carte de 360) au
    // lieu d'une taille fixe : dans un cadre plus étroit il ne déborde pas trop.
    final w = box.maxWidth.isFinite ? box.maxWidth : 360.0;
    final mark = w * 1.1;
    return ClipRRect(
      borderRadius: _kPassportRadius,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [SC.brandBlueDeep, SC.brandBlue, SC.brandCyan],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -w * 0.42,
              top: -w * 0.14,
              width: mark,
              height: mark,
              child: Opacity(
                opacity: 0.16,
                child: Image.asset('assets/glyph-white.png', fit: BoxFit.contain),
              ),
            ),
            Positioned(
              right: 20 + rightInset,
              top: 20,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: SC.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.public_rounded,
                  size: 21,
                  color: Color(0xFF04123A),
                ),
              ),
            ),
            // Remonte au-dessus des boutons ✕ / message / ♥ (flottants par-dessus le
            // panneau) : a 28 du bas, ils cachaient le titre.
            Positioned(
              left: 24,
              bottom: bottomInset,
              right: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'N° $passNo · SWAYCØ',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 10,
                      letterSpacing: 3,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: popupDisplay(
                      fontSize: 24,
                      letterSpacing: -1.0,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sub,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    });
  }
}

/// La première ligne de la page : prénom (Unbounded 800 19) + drapeau en image
/// ronde, puis « Pays - Ville » dessous.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.profile, this.hideFlag = false});

  final RemoteProfile profile;
  final bool hideFlag;

  @override
  Widget build(BuildContext context) {
    final name = profile.displayName.trim().isEmpty
        ? AppStrings.t('profile_anonymous')
        : profile.displayName.trim();
    final country = profile.country.trim();
    final iso = hideFlag ? '' : countryIso2For(country);
    final emoji = hideFlag
        ? null
        : (countryFlagFor(country) ??
            findLanguageByCode(profile.language)?.flag);
    final city = profile.city.trim();
    final placeText = [
      if (country.isNotEmpty) country,
      if (city.isNotEmpty) city,
    ].join(' - ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: popupDisplay(
                  fontSize: 19,
                  letterSpacing: -0.76,
                  color: SC.light ? const Color(0xFF04123A) : Colors.white,
                ),
              ),
            ),
            if (iso.isNotEmpty || emoji != null) ...[
              const SizedBox(width: 8),
              iso.isNotEmpty
                  ? ClipOval(
                      child: Image.network(
                        'https://flagcdn.com/w80/${iso.toLowerCase()}.png',
                        width: 14,
                        height: 14,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Text(
                          emoji ?? '',
                          style: const TextStyle(fontSize: 13, height: 1),
                        ),
                      ),
                    )
                  : Text(
                      emoji ?? '',
                      style: const TextStyle(fontSize: 13, height: 1),
                    ),
            ],
          ],
        ),
        if (placeText.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            placeText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: SC.light
                  ? const Color(0xB304123A)
                  : const Color(0xBFFFFFFF),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Empty / end-of-deck
// ══════════════════════════════════════════════════════════════════════════════

/// Shown after the last Discover card — Restart replays from the first card.
class _DiscoverDone extends StatelessWidget {
  const _DiscoverDone({required this.onRestart});
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onRestart,
        borderRadius: BorderRadius.circular(28),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    color: SC.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: SC.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(
                    Icons.replay_rounded,
                    color: SC.accentFg,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  AppStrings.t('discover_done'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: SC.fg,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  AppStrings.t('discover_done_back'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: SC.fg.withValues(alpha: 0.55),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 22),
                TextButton.icon(
                  onPressed: onRestart,
                  icon: Icon(Icons.refresh, color: SC.accentFg),
                  label: Text(
                    AppStrings.t('restart'),
                    style: TextStyle(color: SC.accentFg),
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

class _Empty extends StatefulWidget {
  const _Empty({
    required this.onReset,
    required this.onChooseCountries,
    this.body,
  });
  final VoidCallback onReset;
  final VoidCallback onChooseCountries;

  /// Override for the sub-line — used by the country filter's empty state.
  final String? body;

  @override
  State<_Empty> createState() => _EmptyState();
}

class _EmptyState extends State<_Empty> with SingleTickerProviderStateMixin {
  late final AnimationController _waves = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  // Trois pays pris au hasard parmi ceux du globe, tirés une fois.
  late final List<String> _flags = (kGlobeCountries.values
          .map((c) => c.code)
          .toList()
        ..shuffle())
      .take(3)
      .toList();

  @override
  void dispose() {
    _waves.dispose();
    super.dispose();
  }

  Widget _wave(double delay) {
    return AnimatedBuilder(
      animation: _waves,
      builder: (_, _) {
        // 2,4 s d'onde, décalées de 0,8 s : phase sur un cycle de 3,2 s.
        final t = ((_waves.value * 3.2 - delay) / 2.4);
        if (t < 0 || t > 1) return const SizedBox.shrink();
        final e = Curves.easeOut.transform(t);
        return Opacity(
          opacity: 0.7 * (1 - e),
          child: Transform.scale(
            scale: 0.6 + 0.9 * e,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: SC.brandCyan, width: 1.5),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _flag(String code) {
    return Container(
      width: 44,
      height: 30,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          'https://flagcdn.com/w160/$code.png',
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => ColoredBox(color: SC.fgA(0.2)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final custom = widget.body != null;
    return LayoutBuilder(
      builder: (context, box) => Stack(
        alignment: Alignment.center,
        children: [
          // Halo derrière le bloc, centré vers le haut.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.45),
                    radius: 0.55,
                    colors: [
                      SC.brandBlue.withValues(alpha: 0.5),
                      SC.brandCyan.withValues(alpha: 0.14),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 220,
                    height: 220,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        _wave(0),
                        _wave(0.8),
                        _wave(1.6),
                        Container(
                          width: 160,
                          height: 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: const Alignment(-0.5, -1),
                              end: const Alignment(0.5, 1),
                              colors: SC.brandGradient.colors,
                              stops: SC.brandGradient.stops,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: SC.brandBlue.withValues(alpha: 0.5),
                                blurRadius: 40,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.public_rounded,
                            size: 70,
                            color: Colors.white,
                          ),
                        ),
                        Positioned(left: 4, top: 22, child: _flag(_flags[0])),
                        Positioned(right: 0, top: 86, child: _flag(_flags[1])),
                        Positioned(left: 14, bottom: 14, child: _flag(_flags[2])),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Text(
                      AppStrings.t('discover_end_title'),
                      textAlign: TextAlign.center,
                      style: popupDisplay(
                        fontSize: 26,
                        letterSpacing: -1.04,
                        height: 1.1,
                        color: SC.fg,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Text(
                      custom
                          ? widget.body!
                          : AppStrings.t('discover_end_body'),
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14.5,
                        height: 1.45,
                        color: SC.fgA(0.75),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onChooseCountries,
                      child: Container(
                        height: 54,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: SC.accent,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: SC.accent.withValues(alpha: 0.5),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.explore_rounded,
                              size: 20,
                              color: SC.onAccent,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                AppStrings.t('discover_end_countries'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: popupDisplay(
                                  fontSize: 14,
                                  color: SC.onAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onReset,
                      child: Container(
                        height: 50,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: SC.fgA(0.10),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: SC.fgA(0.25), width: 1.2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.refresh_rounded, size: 19, color: SC.fg),
                            const SizedBox(width: 8),
                            Text(
                              AppStrings.t('discover_end_retry'),
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: SC.fg,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
