import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../services/ad_service.dart';
import '../services/app_strings.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'discover_ad_card.dart';
import 'interest_chip.dart' show interestPillText;
import 'round_flag.dart';
import 'translated_profile_text.dart';
import 'voice_intro_player.dart';
import 'voice_intro_translation.dart';

/// Une carte du fil : la personne et ses photos (au moins une).
typedef FeedEntry = ({RemoteProfile profile, List<String> photos});

const Color _kInk = Color(0xFF04123A);
const Color _kYellow = Color(0xFFF4FF1F);
const Color _kHeart = Color(0xFFFF3B5C);
const Color _kBlue = Color(0xFF1F5EFF);
const Color _kCyan = Color(0xFF18DDEA);

/// La photo de la carte (« photo centrée ») : 160 × 244 sur un écran de 390. Sur
/// un écran plus étroit elle rétrécit, pour laisser sa place à la colonne.
const double _kPhotoWidth = 160;
const double _kPhotoHeight = 244;
const double _kPhotoShare = 0.476;
const double _kMinCardHeight = 198;

/// Hauteur donnée à une carte publicitaire dans le fil.
const double _kAdHeight = 400;

Color _ink(double alpha) =>
    (SC.light ? _kInk : Colors.white).withValues(alpha: alpha);

/// Discover en fil : une liste verticale de cartes, une personne par carte.
class DiscoverFeed extends StatefulWidget {
  const DiscoverFeed({
    super.key,
    required this.controller,
    required this.entries,
    required this.likedIds,
    required this.onToggleLike,
    required this.onOpenProfile,
    required this.onOpenPhotos,
    required this.canWrite,
    required this.onSend,
    required this.onSeen,
    required this.onScrollMoved,
    required this.onComposing,
    required this.nextAdGap,
    required this.footer,
    required this.bottomSpace,
  });

  final ScrollController controller;
  final List<FeedEntry> entries;
  final Set<String> likedIds;
  final ValueChanged<RemoteProfile> onToggleLike;
  final ValueChanged<RemoteProfile> onOpenProfile;
  /// Toucher la photo : la visionneuse s'ouvre sur la photo affichée.
  final void Function(FeedEntry entry, int index) onOpenPhotos;

  /// Puis-je écrire à cette personne ? (limite du jour des comptes gratuits)
  final Future<bool> Function(RemoteProfile) canWrite;

  /// Envoie le message ; `true` quand il est parti.
  final Future<bool> Function(RemoteProfile, String) onSend;

  /// Une carte vient d'être dépassée : un profil « vu ».
  final ValueChanged<RemoteProfile> onSeen;

  /// À chaque mouvement du défilement.
  final void Function(ScrollMetrics metrics, double delta) onScrollMoved;

  /// Le champ de message s'ouvre / se ferme.
  final ValueChanged<bool> onComposing;

  /// Nombre de cartes avant la prochaine publicité.
  final int Function() nextAdGap;

  /// Sous la dernière carte.
  final Widget footer;

  /// Marge sous la liste (la barre du bas).
  final double bottomSpace;

  @override
  State<DiscoverFeed> createState() => _DiscoverFeedState();
}

class _DiscoverFeedState extends State<DiscoverFeed> {
  final _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _cardKeys = {};
  final Set<String> _seen = {};

  /// Les personnes APRÈS lesquelles s'insère une publicité.
  final Set<String> _adAfter = {};

  /// Publicités fermées : elles ne reviennent pas.
  final Set<String> _adDone = {};

  String? _writingTo;
  bool _sending = false;
  final _draft = TextEditingController();
  final _focus = FocusNode();
  Timer? _reveal;

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

  @override
  void dispose() {
    _reveal?.cancel();
    _draft.dispose();
    _focus.dispose();
    super.dispose();
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

  void _see(RemoteProfile p) {
    if (_seen.add(p.id)) widget.onSeen(p);
  }

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
      // Passée sous le haut de la liste — ou on est au bout du fil.
      if (top + box.size.height < 48 || atEnd) _see(e.profile);
    }
  }

  // ── Écrire depuis la carte ─────────────────────────────────────────────────

  Future<void> _toggleComposer(RemoteProfile p) async {
    if (_writingTo == p.id) {
      _closeComposer();
      return;
    }
    if (!await widget.canWrite(p) || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _writingTo = p.id;
      _draft.clear();
    });
    widget.onComposing(true);
    _see(p);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    // La carte monte en haut de la liste.
    _reveal?.cancel();
    _reveal = Timer(const Duration(milliseconds: 60), () {
      final box = _cardKeys[p.id]?.currentContext?.findRenderObject();
      if (!mounted || box == null || !widget.controller.hasClients) return;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) return;
      final target = viewport.getOffsetToReveal(box, 0).offset - 8;
      final max = widget.controller.position.maxScrollExtent;
      widget.controller.animateTo(
        target.clamp(0.0, max),
        duration: const Duration(milliseconds: 350),
        curve: const Cubic(0.2, 0.9, 0.25, 1),
      );
    });
  }

  void _closeComposer() {
    if (_writingTo == null) return;
    _focus.unfocus();
    setState(() => _writingTo = null);
    widget.onComposing(false);
  }

  Future<void> _submit(RemoteProfile p) async {
    final text = _draft.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.onSend(p, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok && _writingTo == p.id) _closeComposer();
  }

  @override
  Widget build(BuildContext context) {
    final composing = _writingTo != null;
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
      builder: (context, box) => Stack(
        key: _viewportKey,
        children: [
          Positioned.fill(
            // Les 24 premiers pixels sont estompés : les cartes glissent sous
            // la rangée de pays.
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) {
                double at(double px) =>
                    rect.height <= 0 ? 0 : (px / rect.height).clamp(0.0, 1.0);
                return LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: const [
                    Color(0x73000000),
                    Color(0xBF000000),
                    Color(0xED000000),
                    Color(0xFF000000),
                  ],
                  stops: [0, at(8), at(16), at(24)],
                ).createShader(rect);
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.depth != 0 || n.metrics.axis != Axis.vertical) {
                    return false;
                  }
                  if (n is ScrollUpdateNotification) {
                    widget.onScrollMoved(n.metrics, n.scrollDelta ?? 0);
                    _trackSoon();
                  }
                  return false;
                },
                child: ListView.builder(
                  controller: widget.controller,
                  physics: const AlwaysScrollableScrollPhysics(),
                  // ignore: deprecated_member_use
                  cacheExtent: 900,
                  padding: EdgeInsets.fromLTRB(
                    // La même marge que la barre du bas.
                    20,
                    8,
                    20,
                    // En écrivant : de quoi monter même la dernière carte.
                    composing ? box.maxHeight : widget.bottomSpace,
                  ),
                  itemCount: items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == items.length) return widget.footer;
                    final item = items[i];
                    final entry = item.entry;
                    if (entry == null) {
                      return _KeepAlive(
                        key: ValueKey('ad-${item.ad}'),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SizedBox(
                            height: _kAdHeight,
                            child: DiscoverAdCard(
                              onDone: () {
                                if (mounted) {
                                  setState(() => _adDone.add(item.ad));
                                }
                              },
                            ),
                          ),
                        ),
                      );
                    }
                    final p = entry.profile;
                    final writing = _writingTo == p.id;
                    return Padding(
                      key: ValueKey('card-${p.id}'),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: KeyedSubtree(
                        key: _keyOf(p.id),
                        child: _FeedCard(
                          entry: entry,
                          liked: widget.likedIds.contains(p.id),
                          onOpenProfile: () => widget.onOpenProfile(p),
                          onOpenPhotos: (index) =>
                              widget.onOpenPhotos(entry, index),
                          onLike: () => widget.onToggleLike(p),
                          onMessage: () => _toggleComposer(p),
                          composer: writing
                              ? _Composer(
                                  controller: _draft,
                                  focusNode: _focus,
                                  sending: _sending,
                                  onClose: _closeComposer,
                                  onSend: () => _submit(p),
                                )
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 96,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: composing ? 0 : 1,
                duration: const Duration(milliseconds: 250),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: SC.light
                          ? const [Color(0x00F3F4F8), Color(0xEBF3F4F8)]
                          : [
                              SC.bgDeep.withValues(alpha: 0),
                              SC.bgDeep.withValues(alpha: 0.8),
                            ],
                    ),
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
    required this.onOpenPhotos,
    required this.onLike,
    required this.onMessage,
    this.composer,
  });

  final FeedEntry entry;
  final bool liked;
  final VoidCallback onOpenProfile;
  final ValueChanged<int> onOpenPhotos;
  final VoidCallback onLike;
  final VoidCallback onMessage;

  /// Non nul : le champ de message est déplié, à la place des boutons.
  final Widget? composer;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final p = entry.profile;
    final name = p.displayName.trim().isEmpty ? '—' : p.displayName.trim();
    final title = p.age != null ? '$name, ${p.age}' : name;
    final country = p.country.trim();
    final bio = p.bio.trim();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpenProfile,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: light ? const Color(0xFFF8F9FC) : null,
          gradient: light
              ? null
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x2BFFFFFF), Color(0x14FFFFFF)],
                ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: light ? const Color(0x1F04123A) : const Color(0x42FFFFFF),
          ),
          // Pas d'ombre sur le verre sombre : elle se verrait au travers.
          boxShadow: light
              ? const [
                  BoxShadow(
                    color: Color(0x4704123A),
                    blurRadius: 24,
                    spreadRadius: -10,
                    offset: Offset(0, 12),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, box) {
                final photoWidth =
                    math.min(_kPhotoWidth, box.maxWidth * _kPhotoShare);
                final height = math.max(
                  _kMinCardHeight,
                  photoWidth * _kPhotoHeight / _kPhotoWidth,
                );
                return SizedBox(
                  height: height,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CardPhoto(
                            entry: entry,
                            width: photoWidth,
                            onTap: onOpenPhotos,
                          ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _ink(1),
                                            fontSize: 19,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.4,
                                          ),
                                        ),
                                      ),
                                      if (p.isVerified) ...[
                                        const SizedBox(width: 6),
                                        const Icon(Icons.verified_rounded,
                                            size: 17, color: _kBlue),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _ink(light ? 0.07 : 0.12),
                                  ),
                                  child: Icon(Icons.chevron_right_rounded,
                                      size: 20, color: _ink(0.7)),
                                ),
                              ],
                            ),
                            if (country.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  RoundFlag(
                                      country: country, language: p.language),
                                  const SizedBox(width: 7),
                                  Flexible(
                                    child: Text(
                                      country,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _ink(0.72),
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ClipRect(
                                  child: p.hasVoiceIntro
                                      ? VoiceIntroPlayer(
                                          url: p.voiceIntroUrl,
                                          durationMs: p.voiceIntroDurationMs,
                                          compact: true,
                                        )
                                      : bio.isEmpty && p.interests.isNotEmpty
                                          ? _InterestPills(tags: p.interests)
                                          : bio.isEmpty
                                      ? Text(
                                          AppStrings.t('peer_bio_empty'),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _ink(0.45),
                                            fontSize: 12.5,
                                            height: 1.4,
                                          ),
                                        )
                                      : TranslatedProfileText(
                                          text: bio,
                                          profileId: p.id,
                                          field: 'bio',
                                          fromLang: p.language,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _ink(0.72),
                                            fontSize: 12.5,
                                            height: 1.4,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            if (composer == null)
                              Row(
                                children: [
                                  // « Message » prend toute la place, le cœur
                                  // reste tout à droite.
                                  Expanded(
                                    child: _MessageButton(onTap: onMessage),
                                  ),
                                  const SizedBox(width: 8),
                                  _HeartButton(liked: liked, onTap: onLike),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // La traduction de l'audio, seulement pendant l'écoute.
            if (p.hasVoiceIntro && p.voiceIntroTranscript.trim().isNotEmpty)
              VoiceIntroTranslation(profile: p, divider: true),
            if (composer != null) ...[
              const SizedBox(height: 12),
              composer!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Sans bio ni audio : quelques centres d'intérêt, sur deux lignes au plus.
class _InterestPills extends StatelessWidget {
  const _InterestPills({required this.tags});

  final List<String> tags;

  static const double _gap = 5;
  static const double _pill = 25;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: _ink(0.85),
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      height: 1.2,
    );
    return LayoutBuilder(
      builder: (context, box) {
        // Autant de puces entières que deux lignes en acceptent.
        final scaler = MediaQuery.textScalerOf(context);
        final shown = <String>[];
        var line = 1;
        var used = 0.0;
        for (final tag in tags) {
          final label = interestPillText(tag);
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: DefaultTextStyle.of(context).style.merge(style),
            ),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width + 20;
          painter.dispose();
          if (width > box.maxWidth) continue;
          final next = used == 0 ? width : used + _gap + width;
          if (next <= box.maxWidth) {
            used = next;
          } else {
            if (line == 2) break;
            line++;
            used = width;
          }
          shown.add(label);
        }
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final label in shown)
              Container(
                height: _pill,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  color: SC.light
                      ? const Color(0xFFF0F2F8)
                      : const Color(0x1AFFFFFF),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: SC.light
                        ? const Color(0x2404123A)
                        : const Color(0x33FFFFFF),
                  ),
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text(label, maxLines: 1, style: style),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CardPhoto extends StatefulWidget {
  const _CardPhoto({
    required this.entry,
    required this.width,
    required this.onTap,
  });

  final double width;
  final FeedEntry entry;
  final ValueChanged<int> onTap;

  @override
  State<_CardPhoto> createState() => _CardPhotoState();
}

class _CardPhotoState extends State<_CardPhoto> {
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
    final index = _index.clamp(0, photos.length - 1);
    // Au-delà de 5 photos, le point avance en proportion.
    final active = photos.length <= 5
        ? index
        : (index * 4 / (photos.length - 1)).round();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap(index),
      child: SizedBox(
        width: widget.width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
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
                  physics: const PageScrollPhysics(
                      parent: ClampingScrollPhysics()),
                  itemCount: photos.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => Image.network(
                    photos[i],
                    fit: BoxFit.cover,
                    // Cadrée sur le visage.
                    alignment: const Alignment(0, -0.3),
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p.isPro || p.isPlus)
                      _Badge(
                        text: AppStrings.t('paywall_popular'),
                        color: _kYellow,
                        textColor: _kInk,
                      ),
                    if ((p.isPro || p.isPlus) && p.isNewcomer)
                      const SizedBox(height: 4),
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
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 44,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0x66000000)],
                      ),
                    ),
                  ),
                ),
              ),
              if (dots > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Row(
                    key: ValueKey('dots-${p.id}-$active'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < dots; i++)
                        Container(
                          width: i == active ? 16 : 4,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: Colors.white
                                .withValues(alpha: i == active ? 1 : 0.55),
                            borderRadius: BorderRadius.circular(99),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _MessageButton extends StatelessWidget {
  const _MessageButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          // En clair, un dégradé plus foncé : le cyan se fondait dans le fond.
          gradient: LinearGradient(
            colors: light
                ? const [Color(0xFF1747E0), _kBlue, Color(0xFF2B8CFF)]
                : const [_kBlue, Color(0xFF2B7FFF), _kCyan],
            stops: const [0, 0.55, 1],
          ),
          borderRadius: BorderRadius.circular(99),
          boxShadow: light
              ? const [
                  BoxShadow(
                    color: Color(0x801F5EFF),
                    blurRadius: 12,
                    spreadRadius: -4,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        // Petit écran : l'icône laisse sa place, le mot reste lisible.
        child: LayoutBuilder(
          builder: (context, box) => Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (box.maxWidth >= 84) ...[
                    const Icon(Icons.chat_bubble_rounded,
                        size: 19, color: Colors.white),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    AppStrings.t('profile_message'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Le cœur : contour au repos, rouge et plein une fois liké, avec un « pop ».
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
    final light = SC.light;
    return Semantics(
      button: true,
      toggled: widget.liked,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: light ? const Color(0x1204123A) : const Color(0x24FFFFFF),
            border: Border.all(
              color:
                  light ? const Color(0x2404123A) : const Color(0x42FFFFFF),
            ),
          ),
          child: AnimatedBuilder(
            animation: _pop,
            builder: (context, child) =>
                Transform.scale(scale: _scale(_pop.value), child: child),
            child: Icon(
              widget.liked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              size: 26,
              color: widget.liked ? _kHeart : _ink(1),
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Le champ de message, dans la carte
// ════════════════════════════════════════════════════════════════════════════

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onClose,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onClose;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    // Un tap sur le champ ou ses boutons ne doit pas ouvrir le profil.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    light ? const Color(0x1204123A) : const Color(0x24FFFFFF),
                border: Border.all(
                  color: light
                      ? const Color(0x2404123A)
                      : const Color(0x42FFFFFF),
                ),
              ),
              child: Icon(Icons.close_rounded, size: 22, color: _ink(1)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              constraints:
                  const BoxConstraints(minHeight: 40, maxHeight: 94),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color:
                    light ? const Color(0xFFF8F9FC) : const Color(0x24FFFFFF),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: _kYellow, width: 1.5),
                boxShadow: light
                    ? const [
                        BoxShadow(
                          color: Color(0x2604123A),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                cursorColor: light ? _kBlue : _kYellow,
                style: TextStyle(
                  color: _ink(1),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  isCollapsed: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: AppStrings.t('dm_write_hint'),
                  hintMaxLines: 1,
                  hintStyle: TextStyle(
                    color: _ink(0.5),
                    fontSize: 14,
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
              final ready = value.text.trim().isNotEmpty && !sending;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: ready ? onSend : null,
                child: Opacity(
                  opacity: ready || sending ? 1 : 0.55,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kYellow,
                    ),
                    child: sending
                        ? const Padding(
                            padding: EdgeInsets.all(11),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _kInk,
                            ),
                          )
                        : const Icon(Icons.arrow_upward_rounded,
                            size: 22, color: _kInk),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
