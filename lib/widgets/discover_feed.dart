import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ad_service.dart';
import '../services/app_strings.dart';
import '../services/persona_categories.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'discover_ad_card.dart';
import 'feed_snap.dart';
import 'interest_chip.dart' show interestPillText;
import 'round_flag.dart';

/// Une carte du fil : la personne et ses photos (au moins une).
typedef FeedEntry = ({RemoteProfile profile, List<String> photos});

const Color _kInk = Color(0xFF04123A);
const Color _kYellow = Color(0xFFF4FF1F);
const Color _kBlue = Color(0xFF1F5EFF);
const Color _kCyan = Color(0xFF18DDEA);

/// Le cadre en verre (maquette 5a) : 6 px autour d'une photo 4:5.
const double _kFrame = 6;
const double _kFrameRadius = 32;
const double _kPhotoRadius = 26;
const double _kSide = 14;
const double _kGap = 14;
const double _kTopPad = 8;

/// Les boutons chevauchent le bas de la carte : autant dedans que dehors.
const double _kButton = 54;
const double _kOverhang = _kButton / 2;

/// En dessous, la publicité (bannière 300 × 250 et son bouton) ne tient plus.
const double _kMinCardHeight = 380;

/// Discover en fil : une carte par personne, et le défilement s'arrête au
/// milieu de la carte suivante — un geste, une carte.
class DiscoverFeed extends StatefulWidget {
  const DiscoverFeed({
    super.key,
    required this.controller,
    required this.entries,
    required this.likedIds,
    required this.onToggleLike,
    required this.onOpenProfile,
    required this.canWrite,
    required this.onSend,
    required this.onComposing,
    required this.onSeen,
    required this.onScrollMoved,
    required this.nextAdGap,
    required this.footer,
    required this.bottomSpace,
    required this.maxCardHeight,
  });

  final ScrollController controller;
  final List<FeedEntry> entries;
  final Set<String> likedIds;
  final ValueChanged<RemoteProfile> onToggleLike;

  /// Toucher la carte : la page profil (c'est là qu'on écrit).
  final ValueChanged<RemoteProfile> onOpenProfile;

  /// Puis-je écrire à cette personne ? (limite du jour des comptes gratuits)
  final Future<bool> Function(RemoteProfile) canWrite;

  /// Envoie le message ; `true` quand il est parti.
  final Future<bool> Function(RemoteProfile, String) onSend;

  /// Le champ de message s'ouvre / se ferme.
  final ValueChanged<bool> onComposing;

  /// Une carte vient d'être dépassée : un profil « vu ».
  final ValueChanged<RemoteProfile> onSeen;

  /// À chaque mouvement du défilement.
  final void Function(ScrollMetrics metrics, double delta) onScrollMoved;

  /// Nombre de cartes avant la prochaine publicité.
  final int Function() nextAdGap;

  /// Sous la dernière carte.
  final Widget footer;

  /// Marge sous la liste (la barre du bas).
  final double bottomSpace;

  /// La plus grande hauteur qu'une carte peut prendre sur cet écran.
  final double maxCardHeight;

  @override
  State<DiscoverFeed> createState() => _DiscoverFeedState();
}

class _DiscoverFeedState extends State<DiscoverFeed> {
  final _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _cardKeys = {};
  final Set<String> _seen = {};
  final _snap = FeedSnap();

  /// Les personnes APRÈS lesquelles s'insère une publicité.
  final Set<String> _adAfter = {};

  /// Publicités fermées : elles ne reviennent pas.
  final Set<String> _adDone = {};

  /// Dernier cran de molette reçu : une rafale (pavé tactile) = une carte.
  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);

  /// La photo affichée par chaque carte (gardée quand on écrit).
  final Map<String, int> _page = {};

  // ── Écrire ────────────────────────────────────────────────────────────────

  FeedEntry? _writing;
  bool _sending = false;
  final _draft = TextEditingController();
  final Map<String, String> _drafts = {};
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);

  /// D'où la carte part pour rétrécir, et où remettre la liste ensuite.
  double _fromTop = _kTopPad;
  int _heldItem = 0;

  Future<void> _openComposer(FeedEntry entry, int item) async {
    final p = entry.profile;
    if (_writing != null) return;
    if (!await widget.canWrite(p) || !mounted || _writing != null) return;
    HapticFeedback.selectionClick();
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final card = _cardKeys[p.id]?.currentContext?.findRenderObject();
    _fromTop = viewport is RenderBox && card is RenderBox && card.attached
        ? card.localToGlobal(Offset.zero, ancestor: viewport).dy
        : _kTopPad;
    _heldItem = item;
    _snap.frozen = true;
    final text = _drafts[p.id] ?? '';
    _draft.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _writing = entry);
    widget.onComposing(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _writing != null) _focus.requestFocus();
    });
  }

  /// Le clavier s'en va : le champ se referme.
  void _onFocus() {
    if (!_focus.hasFocus && !_sending) _closeComposer();
  }

  /// Referme le champ ; ce qui est écrit reste en brouillon.
  void _closeComposer() {
    final entry = _writing;
    if (entry == null) return;
    _drafts[entry.profile.id] = _draft.text;
    setState(() => _writing = null);
    _focus.unfocus();
    widget.onComposing(false);
    // La liste revient sur la même carte.
    _snap
      ..frozen = false
      ..hold(_heldItem);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.controller.hasClients) return;
      final position = widget.controller.position;
      position.jumpTo(_snap.offsetOf(_heldItem, position));
    });
  }

  Future<void> _submit() async {
    final entry = _writing;
    final text = _draft.text.trim();
    if (entry == null || text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.onSend(entry.profile, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok || _writing?.profile.id != entry.profile.id) return;
    _draft.clear();
    if (_seen.add(entry.profile.id)) widget.onSeen(entry.profile);
    _closeComposer();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _draft.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _placeAds();
  }

  @override
  void didUpdateWidget(DiscoverFeed old) {
    super.didUpdateWidget(old);
    if (old.entries.length != widget.entries.length) _placeAds();
  }

  void _placeAds() {
    if (!AdService.cardAdsEnabled) return;
    var since = 0;
    var gap = widget.nextAdGap();
    for (var i = 0; i < widget.entries.length - 1; i++) {
      since++;
      final id = widget.entries[i].profile.id;
      if (_adAfter.contains(id)) {
        since = 0;
      } else if (since >= gap) {
        _adAfter.add(id);
        since = 0;
        gap = widget.nextAdGap();
      }
    }
  }

  GlobalKey _keyOf(String id) => _cardKeys.putIfAbsent(id, GlobalKey.new);

  // ── Profils vus ────────────────────────────────────────────────────────────

  bool _tracking = false;

  /// Après la mise en page : au moment où le défilement s'annonce, les cartes
  /// sont encore à leur ancienne place.
  void _trackSoon() {
    if (_tracking) return;
    _tracking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tracking = false;
      if (mounted && widget.controller.hasClients) {
        _trackSeen(widget.controller.position);
      }
    });
  }

  void _trackSeen(ScrollMetrics m) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final atEnd = m.pixels >= m.maxScrollExtent - 4;
    for (final e in widget.entries) {
      if (_seen.contains(e.profile.id)) continue;
      final box = _cardKeys[e.profile.id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      // Sa moitié est passée au-dessus de la liste — ou on est au bout du fil.
      if (top + box.size.height / 2 < 0 || atEnd) {
        if (_seen.add(e.profile.id)) widget.onSeen(e.profile);
      }
    }
  }

  // ── Molette / pavé tactile ─────────────────────────────────────────────────

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    if (dy.abs() < 1 || dy.abs() < event.scrollDelta.dx.abs()) return;
    // Pris ici : la liste ne bouge pas d'elle-même.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final now = DateTime.now();
      final quiet = now.difference(_lastWheel).inMilliseconds > 180;
      _lastWheel = now;
      if (!quiet || !widget.controller.hasClients) return;
      _snap.step(widget.controller.position, dy > 0 ? 1 : -1);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Les cartes et les publicités, dans l'ordre.
    final items = <({FeedEntry? entry, String ad})>[];
    for (final e in widget.entries) {
      items.add((entry: e, ad: ''));
      final id = e.profile.id;
      if (_adAfter.contains(id) && !_adDone.contains(id)) {
        items.add((entry: null, ad: id));
      }
    }
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth.isFinite ? box.maxWidth : 390.0;
        final photoWidth = width - 2 * _kSide - 2 * _kFrame - 2;
        final natural = photoWidth * 5 / 4 + 2 * _kFrame + 2;
        final height = math.max(
          _kMinCardHeight,
          math.min(natural, widget.maxCardHeight),
        );
        // La carte, puis la moitié des boutons qui dépasse dessous.
        final block = height + _kOverhang;
        final extent = block + _kGap;
        final writing = _writing;
        _snap
          ..count = items.length
          ..extent = extent
          ..cardHeight = block
          ..topPad = _kTopPad
          ..bottomInset = math.max(0, widget.bottomSpace - 24);
        return Stack(
          key: _viewportKey,
          children: [
            Positioned.fill(
              // Cachée mais gardée pendant qu'on écrit.
              child: Visibility(
                visible: writing == null,
                maintainState: true,
                maintainSize: true,
                maintainAnimation: true,
                child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.depth != 0 || n.metrics.axis != Axis.vertical) {
                    return false;
                  }
                  if (n is ScrollStartNotification && n.dragDetails != null) {
                    _snap.dragStarted(n.metrics);
                  }
                  if (n is ScrollUpdateNotification) {
                    var delta = n.scrollDelta ?? 0;
                    // Pendant l'aimantation, un recalage à contresens (la liste
                    // change de hauteur) n'est pas un mouvement de la personne.
                    if (n.dragDetails == null &&
                        delta.sign != _snap.direction) {
                      delta = 0;
                    }
                    widget.onScrollMoved(n.metrics, delta);
                    _trackSoon();
                  }
                  return false;
                },
                child: ScrollConfiguration(
                  // La souris fait glisser le fil aussi (web).
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: PointerDeviceKind.values.toSet(),
                    scrollbars: false,
                  ),
                  child: CustomScrollView(
                    controller: widget.controller,
                    physics: FeedSnapPhysics(
                      _snap,
                      parent: const AlwaysScrollableScrollPhysics(),
                    ),
                    // ignore: deprecated_member_use
                    cacheExtent: 900,
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                            _kSide, _kTopPad, _kSide, 0),
                        sliver: SliverFixedExtentList(
                          itemExtent: extent,
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final item = items[i];
                              final entry = item.entry;
                              if (entry == null) {
                                return _KeepAlive(
                                  key: ValueKey('ad-${item.ad}'),
                                  child: _wheel(
                                    Align(
                                      alignment: Alignment.topCenter,
                                      child: SizedBox(
                                        height: height,
                                        child: DiscoverAdCard(
                                          onDone: () {
                                            if (mounted) {
                                              setState(
                                                  () => _adDone.add(item.ad));
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              final p = entry.profile;
                              return KeyedSubtree(
                                key: ValueKey('card-${p.id}'),
                                child: _wheel(
                                  Stack(
                                    children: [
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        top: 0,
                                        height: height,
                                        child: KeyedSubtree(
                                          key: _keyOf(p.id),
                                          child: _FeedCard(
                                            entry: entry,
                                            page: _page[p.id] ?? 0,
                                            onPage: (n) => _page[p.id] = n,
                                            onTap: () =>
                                                widget.onOpenProfile(p),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        top: height - _kOverhang,
                                        height: _kButton,
                                        child: _Actions(
                                          liked:
                                              widget.likedIds.contains(p.id),
                                          onMessage: () =>
                                              _openComposer(entry, i),
                                          onLike: () => widget.onToggleLike(p),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                            childCount: items.length,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(child: widget.footer),
                      SliverToBoxAdapter(
                        child: SizedBox(height: widget.bottomSpace),
                      ),
                    ],
                  ),
                ),
                ),
              ),
            ),
            // Les cartes s'estompent en glissant sous la rangée de pays. (Pas de
            // ShaderMask : il éteindrait le verre du cœur.)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 16,
              child: _Fade(top: true),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 96,
              child: _Fade(top: false),
            ),
            if (writing != null)
              Positioned.fill(
                child: PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (_, _) => _closeComposer(),
                  child: _composeLayer(writing, height),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Écrire : la carte rétrécit au-dessus du champ posé sur le clavier. Elle
  /// prend la place qui reste, donc rapetisse encore quand le message grandit.
  Widget _composeLayer(FeedEntry entry, double cardHeight) {
    final p = entry.profile;
    final first = p.displayName.trim().split(RegExp(r'\s+')).first;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closeComposer,
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final room = math.max(0.0, box.maxHeight - 2 * _kTopPad);
                final small = math.min(cardHeight, room);
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) {
                    final from = math.min(cardHeight, box.maxHeight);
                    return Stack(
                      children: [
                        Positioned(
                          left: _kSide,
                          right: _kSide,
                          top: _fromTop + (_kTopPad - _fromTop) * t,
                          height: from + (small - from) * t,
                          child: _FeedCard(
                            entry: entry,
                            page: _page[p.id] ?? 0,
                            onPage: (n) => _page[p.id] = n,
                            onTap: _closeComposer,
                            writing: true,
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          // Toucher le champ ou l'envoi ne ferme pas le clavier.
          TextFieldTapRegion(
            child: _Composer(
              controller: _draft,
              focusNode: _focus,
              name: first,
              sending: _sending,
              onSend: _submit,
            ),
          ),
        ],
      ),
    );
  }

  /// Une carte, son espace dessous, et la molette qui passe à la suivante.
  Widget _wheel(Widget child) => Listener(
        onPointerSignal: _onPointerSignal,
        child: Padding(
          padding: const EdgeInsets.only(bottom: _kGap),
          child: child,
        ),
      );
}

/// Le fondu en haut et en bas de la liste, à la couleur de la page.
class _Fade extends StatelessWidget {
  const _Fade({required this.top});

  final bool top;

  @override
  Widget build(BuildContext context) {
    final Color color = SC.classic
        ? SC.bg
        : (top
            ? (SC.light ? const Color(0xFFE4EDFF) : const Color(0xFF0A1633))
            : (SC.light ? const Color(0xFFF3F4F8) : SC.bgDeep));
    final solid = color.withValues(alpha: top ? 0.7 : 0.85);
    final clear = color.withValues(alpha: 0);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: top ? [solid, clear] : [clear, solid],
          ),
        ),
      ),
    );
  }
}

/// Garde la publicité chargée quand elle sort de l'écran.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({super.key, required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// La carte
// ════════════════════════════════════════════════════════════════════════════

class _FeedCard extends StatelessWidget {
  const _FeedCard({
    required this.entry,
    required this.page,
    required this.onPage,
    required this.onTap,
    this.writing = false,
  });

  final FeedEntry entry;
  final int page;
  final ValueChanged<int> onPage;

  /// Toucher la carte : le profil ; pendant qu'on écrit, fermer le clavier.
  final VoidCallback onTap;

  /// Rétrécie au-dessus du champ : la photo, le prénom et le pays seulement.
  final bool writing;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(_kFrame),
        decoration: BoxDecoration(
          color: light ? const Color(0x0D04123A) : const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(_kFrameRadius),
          border: Border.all(
            color: light ? const Color(0x1F04123A) : const Color(0x29FFFFFF),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_kPhotoRadius),
          child: _CardPhotos(
            entry: entry,
            page: page,
            onPage: onPage,
            badges: !writing,
            overlay: Positioned(
              left: 16,
              right: 16,
              // Au-dessus des boutons qui chevauchent le bas.
              bottom: writing ? 14 : 30,
              // On peut faire défiler les photos en partant du texte.
              child: IgnorePointer(
                child: _CardInfo(profile: entry.profile, chips: !writing),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le carrousel : on fait défiler les photos de gauche à droite dans la carte.
class _CardPhotos extends StatefulWidget {
  const _CardPhotos({
    required this.entry,
    required this.page,
    required this.onPage,
    required this.overlay,
    required this.badges,
  });

  final FeedEntry entry;
  final int page;
  final ValueChanged<int> onPage;

  /// Le nom et les puces, posés sur la photo.
  final Widget overlay;
  final bool badges;

  @override
  State<_CardPhotos> createState() => _CardPhotosState();
}

class _CardPhotosState extends State<_CardPhotos> {
  late final PageController _pages = PageController(initialPage: widget.page);
  late int _index = widget.page;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.entry.profile;
    final photos = widget.entry.photos;
    final dots = photos.length > 5 ? 5 : photos.length;
    final index = photos.isEmpty ? 0 : _index.clamp(0, photos.length - 1);
    // Au-delà de 5 photos, le point avance en proportion.
    final active = photos.length <= 5
        ? index
        : (index * 4 / (photos.length - 1)).round();
    final popular = p.isPro || p.isPlus;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF26304F)),
        ScrollConfiguration(
          // La souris aussi fait défiler (web).
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: PointerDeviceKind.values.toSet(),
            scrollbars: false,
            overscroll: false,
          ),
          child: PageView.builder(
            controller: _pages,
            physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
            itemCount: photos.length,
            onPageChanged: (i) {
              widget.onPage(i);
              setState(() => _index = i);
            },
            itemBuilder: (context, i) => Image.network(
              photos[i],
              fit: BoxFit.cover,
              // Cadrée sur le visage.
              alignment: const Alignment(0, -0.55),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x4D000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xB8000000),
                ],
                stops: [0, 0.22, 0.52, 1],
              ),
            ),
          ),
        ),
        widget.overlay,
        if (dots > 1)
          Positioned(
            left: 0,
            right: 0,
            top: 12,
            child: IgnorePointer(
              child: Row(
                key: ValueKey('dots-${p.id}-$active'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < dots; i++)
                    Container(
                      width: i == active ? 18 : 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: Colors.white
                            .withValues(alpha: i == active ? 1 : 0.55),
                        borderRadius: BorderRadius.circular(99),
                        boxShadow: const [
                          BoxShadow(color: Color(0x59000000), blurRadius: 4),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (widget.badges && (popular || p.isNewcomer))
          Positioned(
            top: 12,
            left: 12,
            child: IgnorePointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (popular)
                    _Badge(
                      text: AppStrings.t('paywall_popular'),
                      color: _kYellow,
                      textColor: _kInk,
                    ),
                  if (popular && p.isNewcomer) const SizedBox(height: 4),
                  if (p.isNewcomer)
                    _Badge(
                      text: AppStrings.t('feed_new_badge'),
                      gradient:
                          const LinearGradient(colors: [_kBlue, _kCyan]),
                      textColor: Colors.white,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// « Prénom, âge », le drapeau et le pays, puis les puces qui tiennent.
class _CardInfo extends StatelessWidget {
  const _CardInfo({required this.profile, this.chips = true});

  final RemoteProfile profile;
  final bool chips;

  static const _shadow = [Shadow(color: Color(0x80000000), blurRadius: 6)];

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final name = p.displayName.trim().isEmpty ? '—' : p.displayName.trim();
    final title = p.age != null ? '$name, ${p.age}' : name;
    final country = p.country.trim();
    final persona = personaCategoryByLabel(p.personaCategory);
    final labels = <String>[
      if (persona != null)
        '${persona.emoji} ${personaCategoryLabel(p.personaCategory)}',
      for (final tag in p.interests) interestPillText(tag),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.4,
                  height: 1.15,
                  shadows: _shadow,
                ),
              ),
            ),
            if (p.isVerified) ...[
              const SizedBox(width: 8),
              Container(
                width: 19,
                height: 19,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_kBlue, _kCyan],
                  ),
                ),
                child: const Icon(Icons.check_rounded,
                    size: 13, color: Colors.white),
              ),
            ],
          ],
        ),
        if (country.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              RoundFlag(country: country, language: p.language, size: 20),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  country,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    shadows: _shadow,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (chips && labels.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ChipRow(labels: labels),
        ],
      ],
    );
  }
}

/// Une seule ligne de puces : celle qui ne tient pas en entier n'est pas
/// affichée.
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.labels});

  final List<String> labels;

  static const double _gap = 6;
  static const double _padding = 10;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      height: 1.2,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final shown = <String>[];
        var used = 0.0;
        for (final label in labels) {
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: DefaultTextStyle.of(context).style.merge(style),
            ),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          // + 2 : le liseré, + 1 : les arrondis de mesure.
          final width = painter.width + 2 * _padding + 3;
          painter.dispose();
          final next = used == 0 ? width : used + _gap + width;
          if (next > box.maxWidth) continue;
          used = next;
          shown.add(label);
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, label) in shown.indexed) ...[
              if (i > 0) const SizedBox(width: _gap),
              Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: _padding),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: const Color(0x38FFFFFF)),
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text(label, maxLines: 1, style: style),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.textColor,
    this.color,
    this.gradient,
  });

  final String text;
  final Color textColor;
  final Color? color;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        gradient: gradient,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: textColor,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Message (dégradé bleu), ami et cœur (verre), à cheval sur le bas de la
/// carte.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.liked,
    required this.onMessage,
    required this.onLike,
  });

  /// Demande envoyée (ou déjà amis) : le cœur et l'ami le disent tous deux.
  final bool liked;
  final VoidCallback onMessage;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final ink = SC.light ? _kInk : Colors.white;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(child: _MessageButton(onTap: onMessage)),
        const SizedBox(width: 10),
        _GlassButton(
          label: AppStrings.t('add_friend_short'),
          selected: liked,
          onTap: onLike,
          child: Icon(
            liked ? Icons.how_to_reg_rounded : Icons.person_add_rounded,
            size: 23,
            color: ink,
          ),
        ),
        const SizedBox(width: 10),
        _HeartButton(liked: liked, onTap: onLike),
      ],
    );
  }
}

class _MessageButton extends StatelessWidget {
  const _MessageButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: _kButton,
        padding: const EdgeInsets.symmetric(horizontal: 30),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_kBlue, Color(0xFF2B7FFF), _kCyan],
            stops: [0, 0.52, 1],
          ),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: const Color(0x47FFFFFF)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x802B7FFF),
              blurRadius: 26,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Center(
          widthFactor: 1,
          // Une langue longue ou un petit écran : le tout rétrécit.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.chat_bubble_rounded,
                    size: 21, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  AppStrings.t('profile_message'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
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

/// Un rond de verre de 54 px (verre Flutter, pas de vue native).
class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Semantics(
      button: true,
      label: label,
      toggled: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Ombre dehors seulement (sous le verre, elle le noircirait), et
            // sans décalage : décalée, elle dessinait un second rond.
            boxShadow: [
              BoxShadow(
                color: light
                    ? const Color(0x2E04123A)
                    : const Color(0x4D000000),
                blurRadius: 14,
                blurStyle: BlurStyle.outer,
              ),
            ],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                width: _kButton,
                height: _kButton,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Le reflet du haut.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: light
                        ? const [Color(0xB3FFFFFF), Color(0x8CFFFFFF)]
                        : const [Color(0x3DFFFFFF), Color(0x24FFFFFF)],
                    stops: const [0, 0.5],
                  ),
                  border: Border.all(
                    color: light
                        ? const Color(0x2404123A)
                        : const Color(0x4DFFFFFF),
                  ),
                ),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le cœur : en contour au repos, il se remplit au toucher, avec un « pop ».
class _HeartButton extends StatefulWidget {
  const _HeartButton({required this.liked, required this.onTap});

  final bool liked;
  final VoidCallback onTap;

  @override
  State<_HeartButton> createState() => _HeartButtonState();
}

class _HeartButtonState extends State<_HeartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: 1,
  );

  @override
  void didUpdateWidget(_HeartButton old) {
    super.didUpdateWidget(old);
    if (widget.liked && !old.liked) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  /// 0,4 → 1,3 (à 60 %) → 1.
  double _scale(double t) {
    if (t < 0.6) return 0.4 + 0.9 * Curves.easeOut.transform(t / 0.6);
    return 1.3 - 0.3 * Curves.easeInOut.transform((t - 0.6) / 0.4);
  }

  @override
  Widget build(BuildContext context) {
    final liked = widget.liked;
    return _GlassButton(
      label: AppStrings.t('discover_like_label'),
      selected: liked,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pop,
        builder: (context, child) =>
            Transform.scale(scale: _scale(_pop.value), child: child),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            key: ValueKey(liked),
            size: 24,
            color: SC.light ? _kInk : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// La barre posée sur le clavier : le champ (jusqu'à 4 lignes) et l'envoi.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.name,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String name;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final ink = light ? _kInk : Colors.white;
    // Un tap sur la barre ne ferme rien.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        color: light ? const Color(0xF5FFFFFF) : const Color(0xF50E0E0E),
        padding: EdgeInsets.fromLTRB(
            12, 10, 12, 10 + MediaQuery.paddingOf(context).bottom),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.centerLeft,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: light
                      ? const Color(0xFFF3F4F8)
                      : const Color(0x1AFFFFFF),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: _kYellow, width: 1.5),
                ),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  cursorColor: light ? _kBlue : _kYellow,
                  style: TextStyle(color: ink, fontSize: 15, height: 1.4),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: AppStrings.t('feed_write_to',
                        args: {'name': name}),
                    hintMaxLines: 1,
                    hintStyle: TextStyle(
                      color: ink.withValues(alpha: 0.5),
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final ready = value.text.trim().isNotEmpty;
                return Semantics(
                  button: true,
                  label: AppStrings.t('send_emoji'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: ready && !sending ? onSend : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ready
                            ? _kYellow
                            : ink.withValues(alpha: 0.14),
                      ),
                      child: sending
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _kInk,
                              ),
                            )
                          : Icon(
                              Icons.arrow_upward_rounded,
                              size: 24,
                              color: ready
                                  ? _kInk
                                  : ink.withValues(alpha: 0.5),
                            ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
