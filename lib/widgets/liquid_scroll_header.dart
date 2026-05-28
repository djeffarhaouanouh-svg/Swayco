import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../theme/swayco_theme.dart';

/// WhatsApp-iOS / Mail-app style header that physically reacts to
/// the user's scroll.
///
///   • While the user drags, the header's collapse parameter `t`
///     (0 = fully expanded, 1 = fully collapsed) tracks the scroll
///     offset 1 : 1 — direct, frame-accurate.
///   • On `ScrollEndNotification` the carry-over velocity is fed
///     into a SpringSimulation that wobbles `t` around its rest
///     position before settling. The header keeps moving for a
///     beat after the finger leaves the glass.
///   • Every visual property — height, horizontal padding, corner
///     radius, blur sigma, title font size, vertical title shift
///     — interpolates by the same `t` so the transition reads as
///     one continuous deformation instead of N independent
///     animations.
///   • The substrate is real frosted glass: saturated backdrop
///     blur (sigma also interpolated by `t`), specular highlight,
///     hairline rim.
class LiquidScrollHeader extends StatefulWidget {
  const LiquidScrollHeader({
    super.key,
    required this.title,
    required this.builder,
    this.maxHeight = 96,
    this.minHeight = 60,
    this.threshold = 80,
    this.trailing,
  });

  final String title;

  /// Builds the scrollable content. The caller MUST attach the
  /// supplied [ScrollController] to its scrollable; the header
  /// listens to it to drive the collapse. `topInset` is the
  /// header's current visual height + safe-area top — pass it as
  /// the scrollable's top padding so the first item is never
  /// hidden under the header.
  final Widget Function(
    BuildContext context,
    ScrollController controller,
    double topInset,
  ) builder;

  /// Header height when fully expanded (scroll offset 0).
  final double maxHeight;

  /// Header height once fully collapsed.
  final double minHeight;

  /// Pixels of scroll over which `t` goes 0 → 1.
  final double threshold;

  /// Optional trailing widget rendered on the right of the
  /// header (e.g. an avatar, a search button).
  final Widget? trailing;

  @override
  State<LiquidScrollHeader> createState() => _LiquidScrollHeaderState();
}

class _LiquidScrollHeaderState extends State<LiquidScrollHeader>
    with SingleTickerProviderStateMixin {
  // ── Physics ──────────────────────────────────────────────────
  //
  // Softer spring than the nav-bar pill — we want a visible
  // wobble on release, not a near-critical settle. Response
  // ≈ 0.55 s, damping ratio ≈ 0.62.
  static const SpringDescription _spring = SpringDescription(
    mass: 1,
    stiffness: 130,
    damping: 14,
  );

  final ScrollController _scroll = ScrollController();
  late final Ticker _ticker;
  SpringSimulation? _sim;
  final Stopwatch _simWatch = Stopwatch();

  /// 0 = expanded, 1 = collapsed.
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _ticker.dispose();
    super.dispose();
  }

  void _onScroll() {
    // While a spring is still settling, hand control back to the
    // scroll position only once the simulation finishes — that
    // way the wobble isn't immediately overwritten.
    if (_sim != null) return;
    final raw = _scroll.hasClients ? _scroll.offset : 0.0;
    // Allow a slight negative `t` so over-scroll at the top
    // physically pushes the header even further open. Capped to
    // -0.18 so it doesn't grow grotesquely large.
    final mapped = raw / widget.threshold;
    final next = mapped.clamp(-0.18, 1.0);
    if ((next - _t).abs() > 1e-4) {
      setState(() => _t = next);
    }
  }

  bool _onNotification(ScrollNotification n) {
    if (n is ScrollEndNotification && _scroll.hasClients) {
      // The user has let go. Re-derive the rest-state `t` from
      // the scroll position (no snap — we settle where physics
      // put us) and feed in the carry-over velocity so the
      // header keeps wobbling for a beat. velocity is in t-units
      // per second.
      final restT = (_scroll.offset / widget.threshold).clamp(0.0, 1.0);
      final dragV = n.dragDetails?.primaryVelocity;
      double v = 0;
      if (dragV != null) {
        // Down-drag (positive velocity) → header collapses
        // (positive dt/dT). Magnitude scaled to t-units.
        v = -dragV / widget.threshold;
      }
      _settleTo(restT, v);
    }
    return false;
  }

  void _settleTo(double target, double velocity) {
    _sim = SpringSimulation(_spring, _t, target, velocity);
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
    final done = sim.isDone(t);
    setState(() => _t = next);
    if (done) {
      _sim = null;
      _simWatch.stop();
      _ticker.stop();
      // Re-snap _t to whatever the actual scroll position now
      // says, so the next scroll-tick doesn't have to fight a
      // drifted value.
      _onScroll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final topSafe = MediaQuery.paddingOf(context).top;
    // `tVis` is the clamped, eased version of `_t` that all
    // visual interpolations use. The eased curve gives a softer
    // shoulder near full-expansion (where the eye lingers most)
    // and a tighter pull near full-collapse — same shape
    // UIScrollView uses for its title-shrink.
    final tVis = _ease(_t.clamp(0.0, 1.0));

    final height =
        lerpDouble(widget.maxHeight, widget.minHeight, tVis)!;
    final headerTotal = height + topSafe;

    return Stack(
      children: [
        // Content lives behind the header. Top padding equals the
        // header's CURRENT visual height — so the first item sits
        // just below the bar at all times, even as the bar
        // collapses.
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onNotification,
            child: widget.builder(context, _scroll, headerTotal),
          ),
        ),
        // Floating header.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: false,
            child: _HeaderShell(
              title: widget.title,
              tVis: tVis,
              tRaw: _t,
              topSafe: topSafe,
              maxHeight: widget.maxHeight,
              minHeight: widget.minHeight,
              trailing: widget.trailing,
            ),
          ),
        ),
      ],
    );
  }

  /// Custom easing — `easeOutQuint` profile. Pulls the curve hard
  /// towards 1 near the end so the last few pixels of scroll
  /// finish the collapse decisively (otherwise the title hovers
  /// at ~80 % shrunk forever).
  double _ease(double x) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    final u = 1 - x;
    return 1 - u * u * u * u * u;
  }
}

// ─────────────────────────────────────────────────────────────────
// The visual.
// ─────────────────────────────────────────────────────────────────

class _HeaderShell extends StatelessWidget {
  const _HeaderShell({
    required this.title,
    required this.tVis,
    required this.tRaw,
    required this.topSafe,
    required this.maxHeight,
    required this.minHeight,
    required this.trailing,
  });

  final String title;
  /// Eased, clamped [0..1] interpolation parameter.
  final double tVis;
  /// Raw, possibly-negative `_t` — used for the over-scroll bulge.
  final double tRaw;
  final double topSafe;
  final double maxHeight;
  final double minHeight;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // Interpolated visuals.
    final height = lerpDouble(maxHeight, minHeight, tVis)!;
    final hPad = lerpDouble(20, 16, tVis)!;
    final sidePad = lerpDouble(0, 10, tVis)!;
    final radius = lerpDouble(0, 26, tVis)!;
    final fontSize = lerpDouble(30, 17, tVis)!;
    final letterSpacing = lerpDouble(-1.0, -0.2, tVis)!;
    final blurSigma = lerpDouble(18, 32, tVis)!;
    // Background tint strengthens as we collapse — fully
    // expanded the header is barely tinted (you almost see
    // through it onto the content); compact it firms up into a
    // real bar so the title stays legible against the rows
    // scrolling underneath.
    final tintAlpha = lerpDouble(0.0, 0.10, tVis)!;
    // Over-scroll bulge: when tRaw < 0 the bar expands beyond
    // its max height by up to 12 px, a soft rubber feel.
    final overBulge = tRaw < 0 ? (-tRaw) * 60 : 0.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(sidePad, 0, sidePad, 0),
      child: SizedBox(
        height: topSafe + height + overBulge,
        child: Padding(
          padding: EdgeInsets.only(top: topSafe),
          child: ClipRRect(
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(radius),
              bottomRight: Radius.circular(radius),
              topLeft: Radius.circular(tVis > 0.5 ? radius : 0),
              topRight: Radius.circular(tVis > 0.5 ? radius : 0),
            ),
            child: BackdropFilter(
              filter: ImageFilter.compose(
                outer: const ColorFilter.matrix(_saturationMatrix),
                inner: ImageFilter.blur(
                  sigmaX: blurSigma,
                  sigmaY: blurSigma,
                ),
              ),
              child: Stack(
                children: [
                  // Substrate tint.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: tintAlpha),
                      ),
                    ),
                  ),
                  // Soft top-down highlight that thickens as we
                  // collapse — the rim catches light a bit more
                  // once the bar is small and dense.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(
                                alpha: 0.08 + 0.10 * tVis,
                              ),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Hairline base — appears only past the
                  // half-collapse point, where the bar starts
                  // reading as a real boundary against the
                  // scrolling content below.
                  if (tVis > 0.05)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Opacity(
                        opacity: (tVis - 0.05).clamp(0.0, 1.0),
                        child: Container(
                          height: 0.6,
                          color:
                              Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                    ),
                  // Title row.
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: hPad),
                    child: Row(
                      children: [
                        Expanded(
                          child: Align(
                            // Title slides from a left-bottom
                            // "big" anchor (expanded) to a
                            // centred "small" anchor (collapsed).
                            alignment: Alignment(
                              lerpDouble(-1.0, 0.0, tVis)!,
                              lerpDouble(1.0, 0.0, tVis)!,
                            ),
                            child: Padding(
                              padding: EdgeInsets.only(
                                bottom: lerpDouble(8, 0, tVis)!,
                              ),
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: SC.textPrimary,
                                  fontSize: fontSize,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: letterSpacing,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                        ),
                        ?trailing,
                      ],
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

  // Same Rec.709 saturation matrix as the nav-bar substrate
  // (s = 1.5).
  static const List<double> _saturationMatrix = <double>[
     1.39370, -0.35760, -0.03610, 0, 0,
    -0.10630,  1.14240, -0.03610, 0, 0,
    -0.10630, -0.35760,  1.46390, 0, 0,
     0,        0,        0,       1, 0,
  ];
}
