import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

import '../services/app_strings.dart';
import '../services/platform_glass.dart';
import '../theme/swayco_theme.dart';
import 'spring_press.dart';

/// WhatsApp-style lens magnification for the nav icon at index [i], given the
/// continuous pill position [frac]. The icon swells as the pill slides PAST it
/// and returns to its normal size once the pill settles ON it: a parabolic
/// bump that is 1.0 at distance 0 (settled) and 1.0 at distance >= 1 (far),
/// peaking at ~`1 + amp` mid-transit. Tune [amp].
double _navLensScale(int i, double frac, {double amp = 0.45}) {
  final d = (i - frac).abs().clamp(0.0, 1.0);
  return 1.0 + amp * 4.0 * d * (1.0 - d);
}

/// Pill-centred lens magnification: the icon directly under the dragging pill
/// is the biggest (distance 0 → `1 + amp`), tapering back to 1.0 a slot away.
/// Used WHILE dragging the pill, where the icon under the finger should bulge.
double _navPeakLens(int i, double frac, {double amp = 0.45}) {
  final d = (i - frac).abs().clamp(0.0, 1.0);
  return 1.0 + amp * (1.0 - d);
}

/// Full-width glass-morphism bottom-nav, flush against the screen bottom,
/// with a sliding pill that animates between selected tabs. Rendered by
/// [RootShell] and re-used by screens pushed on top of it (e.g. a peer's
/// profile) so the bar stays visible. The bar pads its own bottom by the
/// system safe-area inset, so callers anchor it at `bottom: 0`.
class GlassNavBar extends StatefulWidget {
  const GlassNavBar({
    super.key,
    required this.selected,
    required this.unreadChat,
    required this.unreadRequests,
    required this.onSelect,
    this.hugTopCorners = false,
    this.selectedFraction,
  });

  final int selected;

  /// Continuous tab position (e.g. 1.4 mid-swipe between tabs 1 and 2). When
  /// provided, the highlight pill tracks it in real time so it glides with
  /// the page swipe instead of snapping. Null → the pill just animates
  /// between integer [selected] slots (used by pushed-route nav bars that
  /// have no pager).
  final double? selectedFraction;
  final int unreadChat;

  /// Count of pending friend requests addressed to the local user —
  /// drives the red badge on the Demandes tab.
  final int unreadRequests;
  final ValueChanged<int> onSelect;

  /// When true, the bar grows upward by [hugRadius] at its two top corners
  /// and carves a concave notch into each so it wraps the rounded bottom
  /// corners of the Discover card resting on it. The icon row stays in the
  /// same place either way (the notch strip is added above the body), so
  /// toggling this between tabs never shifts the icons. Off elsewhere.
  final bool hugTopCorners;

  /// Height of the bar's content row (excludes the bottom safe-area inset
  /// and the [hugRadius] notch strip, both padded internally). Exposed so
  /// the Discover deck can reserve exactly this much space and sit flush
  /// against the bar's body top edge.
  static const double height = 56;

  /// Radius of the concave notches carved into the bar's two top corners.
  /// The bar grows upward by this much at the corners so it wraps snugly
  /// around the rounded bottom corners of the Discover card sitting on it —
  /// must match the card's corner radius. Exposed so the card and the
  /// Discover top bar stay in sync.
  static const double hugRadius = 28;

  @override
  State<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<GlassNavBar>
    with SingleTickerProviderStateMixin {
  // ── Drag-to-switch (iOS-26 liquid glass): press & hold the bar, the pill
  // grows, then slide left/right to pick a tab; release snaps to the nearest.
  double? _dragFrac; // pill position override while dragging / settling
  bool _dragging = false; // finger held → pill grown + pill-centred lens
  double _slot = 1; // slot width, cached from the LayoutBuilder each build
  int _count = 1; // number of tabs
  int _lastHovered = -1; // last tab the pill crossed (for a tick of haptic)

  // Snap-back animation played on release: glides the pill from where the
  // finger let go to the nearest tab, then hands control back to the pager.
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _settleFrom = 0;
  double _settleTo = 0;

  @override
  void initState() {
    super.initState();
    _settle
      ..addListener(() {
        setState(() {
          _dragFrac = lerpDouble(
            _settleFrom,
            _settleTo,
            Curves.easeOutCubic.transform(_settle.value),
          );
        });
      })
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          setState(() => _dragFrac = null);
        }
      });
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  // Map a local x (within the icon row) to a continuous tab position so the
  // pill centres under the finger.
  double _fracFromX(double dx) =>
      (dx / _slot - 0.5).clamp(0.0, (_count - 1).toDouble());

  void _onDragStart(double dx) {
    _settle.stop();
    final frac = _fracFromX(dx);
    _lastHovered = frac.round();
    HapticFeedback.selectionClick();
    setState(() {
      _dragging = true;
      _dragFrac = frac;
    });
  }

  void _onDragUpdate(double dx) {
    final frac = _fracFromX(dx);
    // A soft tick each time the pill crosses onto a new tab — iOS-style.
    final hovered = frac.round();
    if (hovered != _lastHovered) {
      _lastHovered = hovered;
      HapticFeedback.selectionClick();
    }
    setState(() => _dragFrac = frac);
  }

  void _onDragEnd() {
    final frac = _dragFrac ?? widget.selected.toDouble();
    final nearest = frac.round().clamp(0, _count - 1);
    widget.onSelect(nearest);
    setState(() => _dragging = false); // pill shrinks + lens off
    _settleFrom = frac;
    _settleTo = nearest.toDouble();
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final selectedFraction = widget.selectedFraction;
    final unreadChat = widget.unreadChat;
    final unreadRequests = widget.unreadRequests;
    final onSelect = widget.onSelect;
    final hugTopCorners = widget.hugTopCorners;
    const height = GlassNavBar.height;
    const hugRadius = GlassNavBar.hugRadius;
    final items = <_NavItemData>[
      _NavItemData(
        icon: Icons.chat_bubble_outline,
        selectedIcon: Icons.chat_bubble,
        label: AppStrings.t('nav_chat'),
        badge: unreadChat,
      ),
      _NavItemData(
        // Card-stack glyph (Discover deck metaphor).
        icon: Icons.style_outlined,
        selectedIcon: Icons.style,
        label: AppStrings.t('nav_search'),
      ),
      _NavItemData(
        icon: Icons.favorite_border,
        selectedIcon: Icons.favorite,
        label: AppStrings.t('nav_demandes'),
        badge: unreadRequests,
      ),
      _NavItemData(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: AppStrings.t('nav_tab3'),
      ),
    ];

    // Pad the bar's own bottom by the system safe-area inset so the glass
    // fills all the way to the screen edge (behind the home indicator)
    // while the icons stay above it.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // The pill + items row — identical in every rendering path.
    final inner = SizedBox(
      height: height,
      child: Padding(
        // Pull the icons in from the screen edges so they sit a bit tighter;
        // the glass bar itself stays full-width. Tune the horizontal inset.
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: LayoutBuilder(
            builder: (context, constraints) {
              // Each tab gets an equal slice of the full width; the pill and
              // the icons share the same slot geometry so they line up. Cache
              // slot/count so the drag gesture can map x → tab position.
              final slot = constraints.maxWidth / items.length;
              _slot = slot;
              _count = items.length;
              // Continuous pill position: a live drag (or its snap-back)
              // overrides everything, then the pager fraction (glides with a
              // swipe), else the settled tab. Drives the pill AND the lens.
              final frac =
                  _dragFrac ?? selectedFraction ?? selected.toDouble();
              final tracking = _dragFrac != null;
              final pillLeft = slot * frac;
              final pill = Center(
                child: AnimatedScale(
                  // Grows while the finger is held, springs back on release.
                  scale: _dragging ? 1.14 : 1.0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: slot - 24,
                    height: height - 16,
                    decoration: BoxDecoration(
                      color: Colors.white
                          .withValues(alpha: _dragging ? 0.26 : 0.18),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.28),
                      ),
                    ),
                  ),
                ),
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Press & hold then slide to switch tabs. A quick tap on an
                // icon still wins the gesture arena (handled by _NavItem).
                onLongPressStart: (d) => _onDragStart(d.localPosition.dx),
                onLongPressMoveUpdate: (d) =>
                    _onDragUpdate(d.localPosition.dx),
                onLongPressEnd: (_) => _onDragEnd(),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    // Sliding highlight pill. A live drag / its snap-back and
                    // a pager swipe both track immediately (plain Positioned);
                    // otherwise it animates between integer slots on tap.
                    if (tracking || selectedFraction != null)
                      Positioned(
                        left: pillLeft,
                        top: 0,
                        bottom: 0,
                        width: slot,
                        child: pill,
                      )
                    else
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        left: pillLeft,
                        top: 0,
                        bottom: 0,
                        width: slot,
                        child: pill,
                      ),
                    // Items — one equal-width slot each.
                    Row(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Expanded(
                            child: SizedBox(
                              height: height,
                              child: _NavItem(
                                data: items[i],
                                selected: selected == i,
                                // Dragging → a lens centred on the pill (icon
                                // under the finger bulges). Otherwise the swipe
                                // bump that settles back to normal size.
                                magnify: _dragging
                                    ? _navPeakLens(i, frac)
                                    : _navLensScale(i, frac),
                                onTap: () => onSelect(i),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

    // Native flat bar → real shader Liquid Glass (single static surface, no
    // platform view). The Discover "hug" state keeps the BackdropFilter path
    // (its concave notches can't be a rounded-superellipse), and web keeps the
    // BackdropFilter design unchanged.
    if (useShaderGlass && !hugTopCorners) {
      return lg.GlassContainer(
        useOwnLayer: true,
        clipBehavior: Clip.antiAlias,
        shape: const lg.LiquidRoundedSuperellipse(borderRadius: 0),
        // Tune blur / thickness / refractiveIndex to taste.
        settings: const lg.LiquidGlassSettings(
          blur: 10,
          thickness: 14,
          glassColor: Color(0x12FFFFFF),
          refractiveIndex: 1.3,
        ),
        padding: EdgeInsets.only(bottom: bottomInset * 0.7),
        child: inner,
      );
    }

    final bar = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          // Plain bar: a hairline top edge. The hugging bar's outline is
          // defined by the concave notch clip instead, so no border there.
          border: hugTopCorners
              ? null
              : Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                ),
        ),
        // Reserve the notch strip on top only when hugging; bottom pad by the
        // safe-area inset. When hugging, the glass also grows UP by the slice we
        // trimmed off the bottom (0.3*inset) so its top edge rises back to the
        // Discover card's bottom and keeps the image covered (no blue gap) —
        // WITHOUT lowering the icon row, which is anchored by the bottom pad.
        padding: EdgeInsets.only(
          top: hugTopCorners ? hugRadius + bottomInset * 0.3 : 0,
          bottom: bottomInset * 0.7,
        ),
        child: inner,
      ),
    );

    // Concave corner notches that hug the Discover card; a plain flat bar on
    // every other tab. The body height is identical either way.
    return hugTopCorners
        ? ClipPath(clipper: const _TopHugClipper(hugRadius), child: bar)
        : ClipRect(child: bar);
  }
}

/// Clips a bar into a full-width rectangle whose two TOP corners are carved
/// out by a concave quarter-circle notch of [radius]. Each notch is the
/// corner square minus the disc that the resting card's rounded corner
/// fills, so the bar and the card tile that corner with no gap or overlap.
class _TopHugClipper extends CustomClipper<Path> {
  const _TopHugClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) {
    final r = radius;
    final w = size.width;
    final h = size.height;
    final leftNotch = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTRB(0, 0, r, r)),
      Path()..addOval(Rect.fromCircle(center: Offset(r, 0), radius: r)),
    );
    final rightNotch = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTRB(w - r, 0, w, r)),
      Path()..addOval(Rect.fromCircle(center: Offset(w - r, 0), radius: r)),
    );
    var path = Path()..addRect(Rect.fromLTRB(0, r, w, h));
    path = Path.combine(PathOperation.union, path, leftNotch);
    path = Path.combine(PathOperation.union, path, rightNotch);
    return path;
  }

  @override
  bool shouldReclip(_TopHugClipper oldClipper) => oldClipper.radius != radius;
}

class _NavItemData {
  const _NavItemData({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badge;
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.data,
    required this.selected,
    required this.magnify,
    required this.onTap,
  });

  final _NavItemData data;
  final bool selected;

  /// Proximity scale from the sliding pill (1.0 far → larger right under it).
  final double magnify;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  // One-shot "pop" played the instant this tab becomes selected: the icon
  // grows past its size, then springs back to normal — the grow-then-shrink
  // on click. Layered (multiplied) on top of the swipe lens magnification.
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  late final Animation<double> _popScale = TweenSequence<double>([
    // Quick grow to the overshoot peak…
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.35)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    // …then a springy settle back to normal size.
    TweenSequenceItem(
      tween: Tween(begin: 1.35, end: 1.0)
          .chain(CurveTween(curve: Curves.elasticOut)),
      weight: 65,
    ),
  ]).animate(_pop);

  @override
  void didUpdateWidget(_NavItem old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Real spring (physics) bounce on press; the pop adds the grow-then-shrink
    // on selection; the swipe lens magnifies as the pill nears.
    return SpringPress(
      onTap: widget.onTap,
      child: Center(
        child: _badged(
          AnimatedBuilder(
            animation: _popScale,
            builder: (context, child) => Transform.scale(
              // Swipe lens × selection pop.
              scale: widget.magnify * _popScale.value,
              child: child,
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                widget.selected
                    ? widget.data.selectedIcon
                    : widget.data.icon,
                key: ValueKey(widget.selected),
                size: 26,
                // Colour transition white → cyan accent on selection (the
                // AnimatedSwitcher cross-fades between the two icons).
                color: widget.selected
                    ? SC.accent
                    : Colors.white.withValues(alpha: 0.78),
              ),
            ),
          ),
          widget.data.badge,
        ),
      ),
    );
  }

  Widget _badged(Widget child, int count) {
    if (count <= 0) return child;
    return Badge.count(
      count: count,
      backgroundColor: SC.accent,
      textColor: SC.bgDeep,
      child: child,
    );
  }
}
