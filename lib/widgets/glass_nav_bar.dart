import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../services/nav_bar_visibility.dart';
import '../theme/swayco_theme.dart';

/// iOS-26 Liquid-Glass bottom-nav.
///
/// Rebuilt around the primitives UIKit's tab bar actually uses:
///
///   • a SpringSimulation drives the pill — no Curves, no
///     AnimatedPositioned, no easeOut. The position is sampled
///     every vsync from the live simulation, so taps are
///     interruptible and the motion has true inertia.
///   • the pill stretches in its direction of travel: width gains
///     up to 22 %, height squashes 10 %, anchor at the trailing
///     edge. The leading edge pulls ahead, the rear catches up.
///   • every per-item visual (opacity, scale, outlined vs filled
///     glyph crossfade) is a continuous function of distance from
///     the live pill position, not a binary `selected ? : :`. No
///     glyph ever jumps.
///   • the substrate is a real liquid-glass stack — saturated
///     backdrop blur, raking specular highlight, hairline inner
///     stroke, contact shadow + ground shadow — composited in
///     that order on a single ClipRRect so there is no overdraw.
class GlassNavBar extends StatefulWidget {
  const GlassNavBar({
    super.key,
    required this.selected,
    required this.unreadChat,
    required this.unreadRequests,
    required this.onSelect,
  });

  final int selected;
  final int unreadChat;
  /// Count of pending friend requests addressed to the local user —
  /// drives the red badge on the Demandes tab.
  final int unreadRequests;
  final ValueChanged<int> onSelect;

  @override
  State<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<GlassNavBar>
    with SingleTickerProviderStateMixin {
  // ── Layout ───────────────────────────────────────────────────
  static const double _height = 58;
  static const double _itemWidth = 66;
  static const double _hPad = 10;
  static const double _vPad = 8;
  static const double _innerHeight = _height - 2 * _vPad;

  // ── Physics ──────────────────────────────────────────────────
  //
  // Response ≈ 0.42 s, damping ratio ≈ 0.80. Critical-ish so the
  // pill settles fast but still leaves the eye a sub-pixel
  // overshoot on long jumps. Tuned by ear against Mail.app's iOS
  // tab bar.
  static const SpringDescription _spring = SpringDescription(
    mass: 1,
    stiffness: 220,
    damping: 24,
  );

  /// Velocity (in fractional-tab units / s) that maps to the
  /// maximum stretch factor. Above this the pill simply caps —
  /// beyond a certain speed further elongation reads as wobble,
  /// not motion. Empirical.
  static const double _maxStretchVelocity = 18.0;

  late final Ticker _ticker;
  SpringSimulation? _sim;
  final Stopwatch _simWatch = Stopwatch();

  /// Pill position in fractional-tab units (0 = first tab, 1 =
  /// second tab …). Driven by the spring; the visual `left` is
  /// just `_pillPos * _itemWidth`.
  double _pillPos = 0;
  double _pillVelocity = 0;

  @override
  void initState() {
    super.initState();
    _pillPos = widget.selected.toDouble();
    _ticker = createTicker(_onTick);
  }

  @override
  void didUpdateWidget(covariant GlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _animateTo(widget.selected.toDouble());
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Start a fresh SpringSimulation from the current visual state
  /// — current position AND current velocity, so taps mid-flight
  /// don't snap; the motion just curves into the new target.
  void _animateTo(double target) {
    _sim = SpringSimulation(_spring, _pillPos, target, _pillVelocity);
    _simWatch
      ..reset()
      ..start();
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration _) {
    final sim = _sim;
    if (sim == null) {
      _ticker.stop();
      return;
    }
    final t = _simWatch.elapsedMicroseconds / 1e6;
    final next = sim.x(t);
    final v = sim.dx(t);
    final done = sim.isDone(t);
    setState(() {
      _pillPos = next;
      _pillVelocity = done ? 0 : v;
    });
    if (done) {
      _sim = null;
      _simWatch.stop();
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = <_NavItemData>[
      _NavItemData(
        icon: Icons.chat_bubble_outline,
        selectedIcon: Icons.chat_bubble,
        label: AppStrings.t('nav_chat'),
        badge: widget.unreadChat,
      ),
      _NavItemData(
        icon: Icons.style_outlined,
        selectedIcon: Icons.style,
        label: AppStrings.t('nav_search'),
      ),
      _NavItemData(
        icon: Icons.group_outlined,
        selectedIcon: Icons.group,
        label: AppStrings.t('nav_demandes'),
        badge: widget.unreadRequests,
      ),
      _NavItemData(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: AppStrings.t('nav_tab3'),
      ),
    ];

    final expandedWidth = _hPad * 2 + _itemWidth * items.length;
    final collapsedWidth = _itemWidth + _hPad * 2;

    return ValueListenableBuilder<bool>(
      valueListenable: NavBarVisibility.collapsed,
      builder: (_, collapsed, _) {
        return RepaintBoundary(
          child: AnimatedContainer(
            // Outer collapse — rare event, fine with a curve.
            duration: const Duration(milliseconds: 380),
            curve: const Cubic(0.22, 0.62, 0.32, 1.0),
            width: collapsed ? collapsedWidth : expandedWidth,
            height: _height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                // Ambient ground shadow — soft and far. Carries the
                // bar visually off the page.
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32),
                  blurRadius: 28,
                  spreadRadius: -4,
                  offset: const Offset(0, 12),
                ),
                // Contact shadow — tight and dark. Anchors the bar
                // so it doesn't look like it floats in vacuum.
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _LiquidGlass(
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _hPad,
                  vertical: _vPad,
                ),
                child: _NavBody(
                  items: items,
                  selected: widget.selected,
                  collapsed: collapsed,
                  pillPos: _pillPos,
                  pillVelocity: _pillVelocity,
                  itemWidth: _itemWidth,
                  innerHeight: _innerHeight,
                  maxStretchVelocity: _maxStretchVelocity,
                  onSelect: (i) {
                    HapticFeedback.selectionClick();
                    NavBarVisibility.reveal();
                    widget.onSelect(i);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Liquid-glass substrate.
// ─────────────────────────────────────────────────────────────────

/// Apple-style frosted glass — saturated backdrop blur, raking
/// specular highlight, hairline rim, all clipped under a single
/// rounded mask so there's no overdraw at the rim.
class _LiquidGlass extends StatelessWidget {
  const _LiquidGlass({required this.child, required this.borderRadius});

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    // UIVisualEffectView under the hood is `saturate(180%) blur(N)`.
    // We compose the saturation matrix with the blur so it costs
    // exactly one offscreen pass instead of two.
    final filter = ImageFilter.compose(
      outer: const ColorFilter.matrix(_saturationMatrix),
      inner: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: filter,
        child: Stack(
          children: [
            // 1. Base tint — barely there, just enough to anchor
            //    the icons against a hot background.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
            // 2. Specular highlight. A diagonal white-to-clear
            //    rake from the upper-left — same trick UIKit's
            //    glass material uses to look "wet". Under the
            //    blur it reads as a sheen, not a tint.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: const Alignment(-1, -1),
                      end: const Alignment(1, 0.4),
                      colors: [
                        Colors.white.withValues(alpha: 0.20),
                        Colors.white.withValues(alpha: 0.04),
                        Colors.white.withValues(alpha: 0.00),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // 3. Inner hairline — bright on top, soft elsewhere.
            //    Makes the rim catch light the way a polished
            //    edge would.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.22),
                      width: 0.6,
                    ),
                  ),
                ),
              ),
            ),
            // 4. Content.
            child,
          ],
        ),
      ),
    );
  }

  /// Rec.709-weighted saturation boost (s = 1.5). Pulls the
  /// chroma of whatever sits behind the bar through the blur so
  /// the glass picks up the mesh gradient rather than going grey.
  /// Derived as:  row_C diagonal = (1−s)·lum_C + s; off-diagonals
  /// in column C′ = (1−s)·lum_C′.
  static const List<double> _saturationMatrix = <double>[
     1.39370, -0.35760, -0.03610, 0, 0,
    -0.10630,  1.14240, -0.03610, 0, 0,
    -0.10630, -0.35760,  1.46390, 0, 0,
     0,        0,        0,       1, 0,
  ];
}

// ─────────────────────────────────────────────────────────────────
// Row body — pill + items.
// ─────────────────────────────────────────────────────────────────

class _NavBody extends StatelessWidget {
  const _NavBody({
    required this.items,
    required this.selected,
    required this.collapsed,
    required this.pillPos,
    required this.pillVelocity,
    required this.itemWidth,
    required this.innerHeight,
    required this.maxStretchVelocity,
    required this.onSelect,
  });

  final List<_NavItemData> items;
  final int selected;
  final bool collapsed;
  final double pillPos;
  final double pillVelocity;
  final double itemWidth;
  final double innerHeight;
  final double maxStretchVelocity;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: innerHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Pill — driven by the spring, stretches with velocity.
          // In collapsed mode there is only one item so we lock
          // the pill at index 0.
          _StretchPill(
            pillPos: collapsed ? 0 : pillPos,
            pillVelocity: collapsed ? 0 : pillVelocity,
            itemWidth: itemWidth,
            innerHeight: innerHeight,
            maxStretchVelocity: maxStretchVelocity,
          ),
          // Items.
          if (collapsed)
            SizedBox(
              width: itemWidth,
              height: innerHeight,
              child: _NavItem(
                data: items[selected],
                t: 1.0,
                onTap: () => onSelect(selected),
              ),
            )
          else
            Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(
                    width: itemWidth,
                    height: innerHeight,
                    child: _NavItem(
                      data: items[i],
                      // Continuous closeness to the pill. 1 when
                      // the pill sits exactly under this tab, 0
                      // once it is one tab away or further. Every
                      // visual property on the item — opacity,
                      // outlined/filled crossfade, scale — flows
                      // from this single number, so nothing jumps.
                      t: (1 - (pillPos - i).abs()).clamp(0.0, 1.0),
                      onTap: () => onSelect(i),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// The pill itself — stretched by live velocity.
// ─────────────────────────────────────────────────────────────────

class _StretchPill extends StatelessWidget {
  const _StretchPill({
    required this.pillPos,
    required this.pillVelocity,
    required this.itemWidth,
    required this.innerHeight,
    required this.maxStretchVelocity,
  });

  final double pillPos;
  final double pillVelocity;
  final double itemWidth;
  final double innerHeight;
  final double maxStretchVelocity;

  @override
  Widget build(BuildContext context) {
    final left = pillPos * itemWidth;

    // Normalised signed velocity, clamped. Sign carries direction
    // of travel; magnitude carries how much we stretch.
    final vNorm = (pillVelocity / maxStretchVelocity).clamp(-1.0, 1.0);
    final mag = vNorm.abs();

    // Up to +22 % X, −10 % Y. Preserves apparent volume so the
    // pill doesn't visually balloon mid-flight.
    final stretchX = 1.0 + mag * 0.22;
    final squashY = 1.0 - mag * 0.10;

    // Anchor at the TRAILING edge so the front of the pill pulls
    // ahead and the rear catches up — the classic "viscous blob"
    // smear UIKit uses on the iPad cursor.
    final originX = vNorm == 0 ? 0.0 : (vNorm > 0 ? -1.0 : 1.0);

    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: itemWidth,
      child: Center(
        child: RepaintBoundary(
          child: Transform(
            alignment: Alignment(originX, 0),
            transform: Matrix4.diagonal3Values(stretchX, squashY, 1),
            child: Container(
              width: itemWidth - 6,
              height: innerHeight - 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.22),
                    Colors.white.withValues(alpha: 0.08),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.32),
                  width: 0.6,
                ),
                boxShadow: [
                  // Subtle cyan halo under the pill — anchors it
                  // visually as the "active" surface without
                  // becoming a glow toy.
                  BoxShadow(
                    color: SC.accent.withValues(alpha: 0.22),
                    blurRadius: 14,
                    spreadRadius: -2,
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

// ─────────────────────────────────────────────────────────────────
// Single tab.
// ─────────────────────────────────────────────────────────────────

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
    required this.t,
    required this.onTap,
  });

  final _NavItemData data;

  /// Continuous closeness to the active pill, 0..1.
  final double t;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  /// 0 = released, 1 = fully pressed. Asymmetric forward/reverse
  /// — touch-down feels instant, touch-up eases out so the icon
  /// doesn't snap back.
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
    reverseDuration: const Duration(milliseconds: 220),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every visual is a smooth function of `t` — no thresholds,
    // no swaps, no AnimatedSwitcher. The glyph itself crossfades
    // between outlined and filled forms by `t`, so the change in
    // weight is a fade-through, not a swap.
    final t = widget.t;
    final iconAlpha = 0.60 + 0.40 * t;
    final iconScale = 1.0 + 0.06 * t;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _press.forward(),
      onTapUp: (_) => _press.reverse(),
      onTapCancel: () => _press.reverse(),
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _press,
        builder: (_, _) {
          // Asymmetric press curve — fast in, slow out.
          final pressT = Curves.easeOut.transform(_press.value);
          final pressedScale = 1.0 - 0.12 * pressT;
          return Center(
            child: _badged(
              Transform.scale(
                scale: iconScale * pressedScale,
                child: _GlyphCrossfade(
                  outlined: widget.data.icon,
                  filled: widget.data.selectedIcon,
                  t: t,
                  alpha: iconAlpha,
                ),
              ),
              widget.data.badge,
            ),
          );
        },
      ),
    );
  }

  Widget _badged(Widget child, int count) {
    if (count <= 0) return child;
    return Badge.count(
      count: count,
      backgroundColor: const Color(0xFFE53935),
      textColor: Colors.white,
      child: child,
    );
  }
}

/// Crossfades the outlined and filled forms of an icon by `t`.
/// Both icons render at every frame and trade opacity — there is
/// no swap, so the weight transitions smoothly rather than
/// snapping at t = 0.5.
class _GlyphCrossfade extends StatelessWidget {
  const _GlyphCrossfade({
    required this.outlined,
    required this.filled,
    required this.t,
    required this.alpha,
  });

  final IconData outlined;
  final IconData filled;
  final double t;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: 1.0 - t,
          child: Icon(
            outlined,
            size: 23,
            color: Colors.white.withValues(alpha: alpha),
          ),
        ),
        Opacity(
          opacity: t,
          child: Icon(
            filled,
            size: 23,
            color: Colors.white.withValues(alpha: alpha),
            shadows: t > 0.5
                ? [
                    Shadow(
                      color: Colors.white.withValues(alpha: 0.45 * t),
                      blurRadius: 10,
                    ),
                  ]
                : null,
          ),
        ),
      ],
    );
  }
}
