import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/material.dart';

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
const Color _kHeart = Color(0xFFFF5C8A);
const Color _kBlue = Color(0xFF1F5EFF);
const Color _kCyan = Color(0xFF18DDEA);

/// Le cadre en verre (maquette 5a) : 6 px autour d'une photo 4:5.
const double _kFrame = 6;
const double _kFrameRadius = 32;
const double _kPhotoRadius = 26;
const double _kSide = 14;
const double _kGap = 14;
const double _kTopPad = 8;

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
        final extent = height + _kGap;
        _snap
          ..count = items.length
          ..extent = extent
          ..cardHeight = height
          ..topPad = _kTopPad
          ..bottomInset = math.max(0, widget.bottomSpace - 24);
        return Stack(
          key: _viewportKey,
          children: [
            Positioned.fill(
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
                                    DiscoverAdCard(
                                      onDone: () {
                                        if (mounted) {
                                          setState(
                                              () => _adDone.add(item.ad));
                                        }
                                      },
                                    ),
                                  ),
                                );
                              }
                              final p = entry.profile;
                              return KeyedSubtree(
                                key: ValueKey('card-${p.id}'),
                                child: _wheel(
                                  KeyedSubtree(
                                    key: _keyOf(p.id),
                                    child: _FeedCard(
                                      entry: entry,
                                      liked: widget.likedIds.contains(p.id),
                                      onOpenProfile: () =>
                                          widget.onOpenProfile(p),
                                      onLike: () => widget.onToggleLike(p),
                                    ),
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
          ],
        );
      },
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
    required this.liked,
    required this.onOpenProfile,
    required this.onLike,
  });

  final FeedEntry entry;
  final bool liked;
  final VoidCallback onOpenProfile;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpenProfile,
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              _CardPhotos(entry: entry),
              Positioned(
                left: 16,
                right: 84, // la place du cœur
                bottom: 14,
                child: _CardInfo(profile: entry.profile),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: _HeartButton(liked: liked, onTap: onLike),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le carrousel : on fait défiler les photos de gauche à droite dans la carte.
class _CardPhotos extends StatefulWidget {
  const _CardPhotos({required this.entry});

  final FeedEntry entry;

  @override
  State<_CardPhotos> createState() => _CardPhotosState();
}

class _CardPhotosState extends State<_CardPhotos> {
  final _pages = PageController();
  int _index = 0;

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
            onPageChanged: (i) => setState(() => _index = i),
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
        if (popular || p.isNewcomer)
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
  const _CardInfo({required this.profile});

  final RemoteProfile profile;

  static const _shadow = [Shadow(color: Color(0x80000000), blurRadius: 6)];

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final name = p.displayName.trim().isEmpty ? '—' : p.displayName.trim();
    final title = p.age != null ? '$name, ${p.age}' : name;
    final country = p.country.trim();
    final persona = personaCategoryByLabel(p.personaCategory);
    final chips = <String>[
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
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ChipRow(labels: chips),
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

/// Le cœur en verre posé sur la photo : rose sur verre au repos, rose plein et
/// lumineux une fois liké, avec un « pop ».
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
    return Semantics(
      button: true,
      toggled: liked,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: liked
                ? const [BoxShadow(color: Color(0x99FF5C8A), blurRadius: 22)]
                : null,
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: liked ? _kHeart : const Color(0x2EFFFFFF),
                  border: Border.all(color: const Color(0x4DFFFFFF)),
                ),
                child: AnimatedBuilder(
                  animation: _pop,
                  builder: (context, child) => Transform.scale(
                    scale: _scale(_pop.value),
                    child: child,
                  ),
                  child: Icon(
                    Icons.favorite_rounded,
                    size: 30,
                    color: liked ? Colors.white : _kHeart,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
