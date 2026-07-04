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

/// Floating island-style glass nav bar. Rendered by [RootShell] as a centred
/// pill that floats above the bottom safe area. Callers must reserve
/// [totalReservedHeight] at the bottom of their content.
class GlassNavBar extends StatefulWidget {
  const GlassNavBar({
    super.key,
    required this.selected,
    required this.unreadChat,
    required this.unreadRequests,
    required this.onSelect,
    this.hugTopCorners = false,  // kept for API compat — no longer used
    this.selectedFraction,
  });

  final int selected;

  /// Continuous tab position (e.g. 1.4 mid-swipe between tabs 1 and 2). When
  /// provided, the highlight pill tracks it in real time so it glides with
  /// the page swipe instead of snapping.
  final double? selectedFraction;
  final int unreadChat;
  final int unreadRequests;
  final ValueChanged<int> onSelect;
  final bool hugTopCorners; // no-op with floating design

  /// Height of the pill content area.
  static const double height = 66;

  /// Gap between the pill bottom and the screen safe-area top.
  static const double floatBottom = 16.0;

  /// Total vertical space to reserve below content (height + float gap).
  static const double totalReservedHeight = height + floatBottom;

  // Kept for callers that still reference hugRadius — value unused in layout.
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
    const height = GlassNavBar.height;
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

    // The pill + items row — identical in every rendering path.
    final inner = SizedBox(
      height: height,
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
      );

    const radius = BorderRadius.all(Radius.circular(36));

    // Shader Liquid Glass path (iOS native).
    if (useShaderGlass) {
      return lg.GlassContainer(
        useOwnLayer: true,
        clipBehavior: Clip.antiAlias,
        shape: const lg.LiquidRoundedSuperellipse(borderRadius: 36),
        settings: const lg.LiquidGlassSettings(
          blur: 12,
          thickness: 14,
          glassColor: Color(0x14FFFFFF),
          refractiveIndex: 1.28,
        ),
        child: inner,
      );
    }

    // BackdropFilter glass path (Android / web).
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.13),
            borderRadius: radius,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.22),
              width: 1.2,
            ),
          ),
          child: inner,
        ),
      ),
    );
  }
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
                color: widget.selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.50),
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
