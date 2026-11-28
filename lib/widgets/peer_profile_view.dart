import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/app_strings.dart';
import '../services/peer_local_time.dart';
import '../services/profile_api.dart';
import '../theme/swayco_theme.dart';
import 'interest_chip.dart';
import 'popup_kit.dart' show popupDisplay;
import 'translated_profile_text.dart';
import 'voice_intro_player.dart';
import 'voice_intro_translation.dart';

const Color _kInk = Color(0xFF04123A);
const Color _kYellow = Color(0xFFF4FF1F);
const Color _kBlue = Color(0xFF1F5EFF);

/// Fond de la page.
Color get _pageColor =>
    SC.light ? const Color(0xFFF3F4F8) : const Color(0xFF0E0E0E);

Color _ink(double alpha) =>
    (SC.light ? _kInk : Colors.white).withValues(alpha: alpha);

double _unit(double x) => x.clamp(0.0, 1.0).toDouble();

/// x²(3 − 2x)
double _smooth(double x) => x * x * (3 - 2 * x);

/// Le profil de quelqu'un d'autre : sa photo en plein fond, et un panneau
/// ouvert en haut qu'on peut tirer vers le bas. Deux positions (haute, basse) ; la photo de profil
/// rétrécit en montant, le fond se floute et la barre du haut apparaît.
class PeerProfileView extends StatefulWidget {
  const PeerProfileView({
    super.key,
    required this.profile,
    required this.name,
    required this.backgroundUrl,
    required this.avatarUrl,
    required this.online,
    required this.back,
    required this.menu,
    required this.children,
    this.badge,
    this.subtitle,
    this.cornerBadge,
    this.onAvatarCornerTap,
    this.startExpanded = true,
    this.bottomInset = 0,
  });

  /// Sous le nom, à la place des puces ville · heure · en ligne.
  final Widget? subtitle;

  /// Petit rond sur la photo de profil (l'appareil photo, sur mon profil).
  final Widget? cornerBadge;
  final VoidCallback? onAvatarCornerTap;

  /// Le panneau s'ouvre en haut ; sinon au milieu.
  final bool startExpanded;

  /// Place prise en bas par la barre de navigation.
  final double bottomInset;

  final RemoteProfile? profile;
  final String name;
  final String backgroundUrl;
  final String avatarUrl;
  final bool online;

  /// « POPULAIRE », posé au bas de la photo de profil.
  final Widget? badge;

  /// Les deux ronds du haut.
  final Widget back;
  final Widget menu;

  /// Le contenu du panneau, de haut en bas.
  final List<Widget> children;

  @override
  State<PeerProfileView> createState() => _PeerProfileViewState();
}

class _PeerProfileViewState extends State<PeerProfileView>
    with SingleTickerProviderStateMixin {
  /// La position du haut du panneau, en pixels depuis le haut de l'écran.
  late final AnimationController _top =
      AnimationController.unbounded(vsync: this, value: -1);
  final _content = ScrollController();

  double _full = 0;
  double _mid = 0;
  bool _expanded = false;

  /// Le geste en cours sur le contenu a-t-il commencé panneau non déployé ?
  bool _draggingContent = false;

  /// Panneau déployé, contenu tout en haut : le doigt qui descend l'emmène.
  bool _pulling = false;
  VelocityTracker? _pullSpeed;

  /// Au bas de la page : le bouton « retour en haut » se montre.
  final _showBackToTop = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _top.addListener(_onTop);
    _content.addListener(_onContentScroll);
  }

  void _onContentScroll() {
    // Après l'image : une correction de défilement peut arriver en pleine mise
    // en page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_content.hasClients) return;
      final position = _content.position;
      _showBackToTop.value =
          position.pixels > 120 && position.extentAfter < 240;
    });
  }

  void _backToTop() {
    HapticFeedback.selectionClick();
    _content.animateTo(
      0,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _top.dispose();
    _content.dispose();
    _showBackToTop.dispose();
    super.dispose();
  }

  void _onTop() {
    final expanded = _top.value <= _full + 8;
    if (expanded != _expanded && mounted) {
      setState(() => _expanded = expanded);
    }
  }

  void _layout(double height, double safeTop) {
    final full = safeTop + 142;
    final lowest = safeTop + 250;
    var mid = height * 470 / 844;
    if (mid < lowest) mid = lowest;
    if (full == _full && mid == _mid) return;
    // À l'ouverture, la position demandée.
    final wasFull = _top.value < 0 ? widget.startExpanded : _expanded;
    _full = full;
    _mid = mid;
    // Posé avant la position : l'écouteur n'a alors rien à reconstruire.
    _expanded = wasFull;
    // Ensuite (rotation, fenêtre redimensionnée) il garde sa position.
    _top.value = wasFull ? full : mid;
  }

  void _drag(DragUpdateDetails d) => _move(d.delta.dy);

  void _move(double dy) {
    _top.stop();
    _top.value = (_top.value + dy).clamp(_full - 12, _mid + 24);
  }

  void _release(DragEndDetails d) => _settle(d.velocity.pixelsPerSecond.dy);

  void _endPull() {
    if (_pulling) {
      _pulling = false;
      _settle(_pullSpeed?.getVelocity().pixelsPerSecond.dy ?? 0);
    }
    _pullSpeed = null;
  }

  void _settle(double velocity) {
    final projected = _top.value + velocity * 0.15;
    final target = (projected - _full).abs() < (projected - _mid).abs()
        ? _full
        : _mid;
    if (target == _mid && _content.hasClients) _content.jumpTo(0);
    _top.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 220, damping: 25),
        _top.value,
        target,
        velocity,
        tolerance: const Tolerance(distance: 0.3, velocity: 4),
      ),
    ).whenComplete(() {
      if (mounted) _top.value = target;
    });
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, box) {
        _layout(box.maxHeight, safeTop);
        // Le contenu ne se reconstruit pas à chaque image du geste.
        final panelBody = _panelBody(safeBottom);
        return AnimatedBuilder(
          animation: _top,
          builder: (context, _) => _scene(box.biggest, safeTop, panelBody),
        );
      },
    );
  }

  Widget _scene(Size size, double safeTop, Widget panelBody) {
    final light = SC.light;
    final top = _top.value;
    final low = _mid + 160;
    final t = _unit((low - top) / (low - _full));
    final ea = _smooth(_unit((low - top) / (low - _mid)));
    final eb = _smooth(_unit((_mid - top) / (_mid - _full)));

    final photo = 140 - 20 * ea - 52 * eb;
    var midCenter = _mid - 210;
    if (midCenter < safeTop + 66) midCenter = safeTop + 66;
    final center =
        midCenter + 20 * (1 - ea) - eb * (midCenter - (safeTop + 42));
    final nameSize = 32 - 12 * eb;
    final nameTop = center + photo / 2 + 16 - 6 * eb;
    final fade = _unit(0.2 * ea + eb);
    final backgroundOpacity = _unit(light ? 1 - fade : 1 - 0.9 * fade);
    final bar = _unit((eb - 0.5) / 0.4);
    final chipsOpacity = _unit(1 - eb / 0.25);
    final backgroundHeight = size.height * 560 / 844;
    final blur = 12 * fade;
    final radius = 32 - 12 * t;

    Widget background = widget.backgroundUrl.isEmpty
        ? const ColoredBox(color: Color(0xFF0B1230))
        : Image.network(
            widget.backgroundUrl,
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.5),
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: Color(0xFF0B1230)),
          );
    if (blur > 0.2) {
      background = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: background,
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Clair : heure et batterie en blanc sur la photo, foncées sur la barre.
      value: (light && bar > 0.5
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light)
          .copyWith(statusBarColor: Colors.transparent),
      child: ColoredBox(
        color: _pageColor,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: backgroundHeight,
              child: Opacity(
                opacity: backgroundOpacity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRect(child: background),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: light
                              ? const [
                                  Color(0x5904123A),
                                  Color(0x0DF3F4F8),
                                  Color(0x9EF3F4F8),
                                  Color(0xFFF3F4F8),
                                ]
                              : const [
                                  Color(0x8C0E0E0E),
                                  Color(0x400E0E0E),
                                  Color(0x730E0E0E),
                                  Color(0xFF0E0E0E),
                                ],
                          stops: light
                              ? const [0, 0.26, 0.52, 1]
                              : const [0, 0.3, 0.62, 1],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // La barre fixe du haut. Toujours là, même invisible : un voisin qui
            // apparaît ou disparaît recréerait le panneau en plein geste.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _full - 2,
              child: IgnorePointer(
                child: Opacity(
                  opacity: bar,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: light
                          ? const Color(0xFFF8F9FC)
                          : const Color(0xE60E0E0E),
                      border: Border(
                        bottom: BorderSide(
                          color: light
                              ? const Color(0x1404123A)
                              : const Color(0x1AFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              top: nameTop,
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: popupDisplay(
                  fontSize: nameSize,
                  letterSpacing: -0.05 * nameSize,
                  height: 1.1,
                  color: _ink(1),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              top: nameTop + nameSize * 1.1 + 10,
              child: IgnorePointer(
                child: Opacity(
                  opacity: chipsOpacity,
                  child: widget.subtitle ?? _chips(),
                ),
              ),
            ),
            // Le panneau.
            Positioned(
              left: 0,
              right: 0,
              top: top,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(radius)),
                  boxShadow: [
                    BoxShadow(
                      color: light
                          ? const Color(0x3304123A)
                          : const Color(0x73000000),
                      blurRadius: 30,
                      offset: const Offset(0, -10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(radius)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: light
                              ? const [Color(0xEBF8F9FC), Color(0xF7F1F3F9)]
                              : const [Color(0xED202642), Color(0xF70F111E)],
                          stops: const [0, 0.55],
                        ),
                      ),
                      child: Stack(
                        children: [
                          // Le contenu, sous la zone de saisie.
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 52,
                            bottom: 0,
                            child: panelBody,
                          ),
                          // La zone de saisie.
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            height: 52,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragUpdate: _drag,
                              onVerticalDragEnd: _release,
                            ),
                          ),
                          Positioned(
                            left: size.width * 0.12,
                            right: size.width * 0.12,
                            top: 0,
                            height: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    const Color(0x0018DDEA),
                                    light
                                        ? const Color(0xB318DDEA)
                                        : const Color(0xB3FFFFFF),
                                    const Color(0x0018DDEA),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // La photo de profil.
            Positioned(
              left: size.width / 2 - photo / 2,
              top: center - photo / 2,
              width: photo,
              height: photo,
              child: _Avatar(
                url: widget.avatarUrl,
                diameter: photo,
                border: 3 - eb,
                badge: widget.badge,
                cornerBadge: widget.cornerBadge,
                onCornerTap: widget.onAvatarCornerTap,
                badgeOpacity: _unit(1 - eb / 0.3),
              ),
            ),
            Positioned(top: safeTop + 6, left: 14, child: widget.back),
            Positioned(top: safeTop + 6, right: 14, child: widget.menu),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom +
                  18 +
                  widget.bottomInset,
              child: Center(
                child: ValueListenableBuilder<bool>(
                  valueListenable: _showBackToTop,
                  builder: (context, show, _) => IgnorePointer(
                    ignoring: !show,
                    child: AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: _BackToTop(onTap: _backToTop),
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

  Widget _panelBody(double safeBottom) {
    // Non déployé : tirer le contenu tire le panneau. Déployé : il défile, et
    // une fois tout en haut, tirer encore vers le bas redescend le panneau.
    return Listener(
      onPointerDown: (e) => _pullSpeed = VelocityTracker.withKind(e.kind),
      onPointerMove: (e) {
        _pullSpeed?.addPosition(e.timeStamp, e.position);
        if (_draggingContent) return;
        if (!_pulling) {
          final atTop = !_content.hasClients || _content.offset <= 0;
          final down = e.delta.dy > 0 && e.delta.dy > e.delta.dx.abs();
          if (!down || !atTop || !_expanded) return;
          _pulling = true;
        }
        _move(e.delta.dy);
      },
      onPointerUp: (_) => _endPull(),
      onPointerCancel: (_) => _endPull(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) =>
            _draggingContent = !_expanded && !_pulling,
        onVerticalDragUpdate: (d) {
          if (_draggingContent) _drag(d);
        },
        onVerticalDragEnd: (d) {
          if (_draggingContent) _release(d);
          _draggingContent = false;
        },
        child: ListView(
          controller: _content,
          physics: _expanded
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.only(
            bottom: 40 + safeBottom + widget.bottomInset,
          ),
          children: widget.children,
        ),
      ),
    );
  }

  /// Ville · heure sur place · en ligne.
  Widget _chips() {
    final p = widget.profile;
    final city = p?.city.trim() ?? '';
    final clock =
        p == null ? null : resolvePeerLocalTime(city: city, country: p.country);
    final chips = <Widget>[
      if (city.isNotEmpty)
        _InfoChip(icon: Icons.location_on, text: city),
      if (clock != null)
        _InfoChip(
          icon: Icons.schedule,
          text: clock.hhmm,
          color: SC.light ? null : const Color(0xFFFF9F43),
        ),
      if (widget.online)
        _InfoChip(text: AppStrings.t('online_now'), dot: true),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, chip) in chips.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            chip,
          ],
        ],
      ),
    );
  }
}

/// Le petit rond à chevron des cartes, tourné vers le haut.
class _BackToTop extends StatelessWidget {
  const _BackToTop({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Semantics(
      button: true,
      label: AppStrings.t('back_to_top'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Posé sur les photos : un fond assez plein pour rester lisible.
            color: light ? const Color(0xE6F8F9FC) : const Color(0xCC202642),
            border: Border.all(
              color: light ? const Color(0x2404123A) : const Color(0x47FFFFFF),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            Icons.keyboard_arrow_up_rounded,
            size: 28,
            color: _ink(0.85),
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.text, this.icon, this.color, this.dot = false});

  final String text;
  final IconData? icon;
  final Color? color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final fg = color ?? _ink(1);
    return Container(
      height: 30,
      padding: const EdgeInsets.fromLTRB(9, 0, 12, 0),
      decoration: BoxDecoration(
        color: light ? const Color(0xBFFFFFFF) : const Color(0x21FFFFFF),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: light ? const Color(0x1F04123A) : const Color(0x47FFFFFF),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF34D27B),
                boxShadow: [
                  BoxShadow(color: Color(0xCC34D27B), blurRadius: 8),
                ],
              ),
            )
          else
            Icon(icon, size: 16, color: fg),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.url,
    required this.diameter,
    required this.border,
    required this.badge,
    required this.badgeOpacity,
    this.cornerBadge,
    this.onCornerTap,
  });

  final Widget? cornerBadge;
  final VoidCallback? onCornerTap;

  final String url;
  final double diameter;
  final double border;
  final Widget? badge;
  final double badgeOpacity;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF26304F),
              boxShadow: [
                BoxShadow(
                  color: Color(0x59000000),
                  blurRadius: 28,
                  offset: Offset(0, 14),
                ),
              ],
            ),
            foregroundDecoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _kYellow, width: border),
            ),
            child: ClipOval(
              child: url.isEmpty
                  ? const Icon(Icons.person_rounded, color: Colors.white54)
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      alignment: const Alignment(0, -0.4),
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const Icon(
                          Icons.person_rounded,
                          color: Colors.white54),
                    ),
            ),
          ),
        ),
        // En bas à droite ; en haut à droite quand « Populaire » occupe le bas.
        if (cornerBadge != null && badgeOpacity > 0)
          Positioned(
            right: -2,
            top: badge == null ? null : -2,
            bottom: badge == null ? -2 : null,
            child: Opacity(
              opacity: badgeOpacity,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCornerTap,
                child: SizedBox.square(
                  dimension: diameter * 0.3 < 22 ? 22 : diameter * 0.3,
                  child: cornerBadge,
                ),
              ),
            ),
          ),
        if (badge != null && badgeOpacity > 0)
          Positioned(
            left: -40,
            right: -40,
            bottom: -9,
            child: Opacity(opacity: badgeOpacity, child: Center(child: badge)),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Les actions
// ════════════════════════════════════════════════════════════════════════════

/// Message · demande d'ami · enregistrer.
class PeerActionRow extends StatelessWidget {
  const PeerActionRow({
    super.key,
    required this.friends,
    required this.requested,
    required this.onMessage,
    required this.onFriend,
    required this.saved,
    required this.onSave,
  });

  /// Profil enregistré (marque-page).
  final bool saved;
  final VoidCallback onSave;

  /// Déjà amis.
  final bool friends;

  /// Ma demande est partie, sans réponse.
  final bool requested;

  final VoidCallback onMessage;

  /// Envoyer (ou accepter) la demande. `null` : pas de bouton.
  final VoidCallback? onFriend;

  @override
  Widget build(BuildContext context) {
    final done = friends || requested;
    return Row(
      children: [
        Expanded(
          child: PeerPrimaryButton(
            label: AppStrings.t('profile_message'),
            icon: Icons.chat_bubble_rounded,
            onTap: onMessage,
          ),
        ),
        if (onFriend != null) ...[
          const SizedBox(width: 10),
          _RoundAction(
            label: AppStrings.t(
                done ? 'peer_friend_sent' : 'peer_friend_add'),
            icon: done ? Icons.how_to_reg_rounded : Icons.person_add_rounded,
            active: requested,
            onTap: done ? null : onFriend,
          ),
        ],
        const SizedBox(width: 10),
        _RoundAction(
          label: AppStrings.t(saved ? 'peer_unsave' : 'peer_save'),
          icon: saved
              ? Icons.bookmark_rounded
              : Icons.bookmark_border_rounded,
          active: saved,
          onTap: onSave,
        ),
      ],
    );
  }
}

/// La pilule au dégradé de marque (« Message », « Débloquer »).
class PeerPrimaryButton extends StatelessWidget {
  const PeerPrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [_kBlue, Color(0xFF2B7FFF), Color(0xFF18DDEA)],
            stops: [0, 0.52, 1],
          ),
          borderRadius: BorderRadius.circular(99),
          boxShadow: const [
            BoxShadow(
              color: Color(0x6B2B7FFF),
              blurRadius: 20,
              spreadRadius: -2,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 24, color: Colors.white),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
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

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? (light ? _kYellow : const Color(0x29F4FF1F))
                : (light ? const Color(0xFFF8F9FC) : const Color(0x1FFFFFFF)),
            border: Border.all(
              color: active && !light
                  ? _kYellow
                  : (light
                      ? const Color(0x1F04123A)
                      : const Color(0x3DFFFFFF)),
            ),
            boxShadow: light
                ? const [
                    BoxShadow(
                      color: Color(0x1A04123A),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 24,
            color: light ? _kInk : (active ? _kYellow : Colors.white),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// La bio
// ════════════════════════════════════════════════════════════════════════════

/// Carte « BIO » : la présentation vocale ou le texte, puis les centres
/// d'intérêt.
class PeerBioCard extends StatelessWidget {
  const PeerBioCard({super.key, required this.profile});

  final RemoteProfile profile;

  @override
  Widget build(BuildContext context) {
    final light = SC.light;
    final bio = profile.bio.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: light ? const Color(0xFFF8F9FC) : null,
        gradient: light
            ? null
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x1AFFFFFF), Color(0x0AFFFFFF)],
              ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: light ? const Color(0x1A04123A) : const Color(0x29FFFFFF),
        ),
        boxShadow: light
            ? const [
                BoxShadow(
                  color: Color(0x1404123A),
                  blurRadius: 20,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppStrings.t('profile_bio_section').toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: _ink(1),
            ),
          ),
          const SizedBox(height: 10),
          // L'audio, s'il existe ; sinon le texte.
          if (profile.hasVoiceIntro) ...[
            VoiceIntroPlayer(
              url: profile.voiceIntroUrl,
              durationMs: profile.voiceIntroDurationMs,
            ),
            if (profile.voiceIntroTranscript.trim().isNotEmpty)
              VoiceIntroTranslation(profile: profile),
          ] else if (bio.isEmpty)
            Text(
              AppStrings.t('peer_bio_empty'),
              style: TextStyle(color: _ink(0.5), fontSize: 14, height: 1.4),
            )
          else
            TranslatedProfileText(
              // Traduite dans la langue de l'interface quand elle diffère.
              text: bio,
              profileId: profile.id,
              field: 'bio',
              fromLang: profile.language,
              showNote: true,
              textAlign: TextAlign.start,
              style: TextStyle(color: _ink(1), fontSize: 15, height: 1.4),
            ),
          if (profile.interests.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in profile.interests)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 8),
                    decoration: BoxDecoration(
                      color: light
                          ? const Color(0xFFF3F4F8)
                          : const Color(0x1FFFFFFF),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: light
                            ? const Color(0x2404123A)
                            : const Color(0x33FFFFFF),
                      ),
                    ),
                    child: Text(
                      interestPillText(tag),
                      style: TextStyle(
                        color: _ink(1),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
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
