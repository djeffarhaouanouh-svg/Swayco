import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;

import '../services/app_strings.dart';
import '../services/platform_glass.dart';
import '../theme/swayco_theme.dart';

/// Full-width glass-morphism bottom-nav, flush against the screen bottom,
/// with a sliding pill that animates between selected tabs. Rendered by
/// [RootShell] and re-used by screens pushed on top of it (e.g. a peer's
/// profile) so the bar stays visible. The bar pads its own bottom by the
/// system safe-area inset, so callers anchor it at `bottom: 0`.
class GlassNavBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
      child: LayoutBuilder(
            builder: (context, constraints) {
              // Each tab gets an equal slice of the full width; the pill
              // and the icons share the same slot geometry so they line up.
              final slot = constraints.maxWidth / items.length;
              // Continuous pill position when a fraction is supplied (glides
              // with the swipe); otherwise the integer slot.
              final pillLeft = slot * (selectedFraction ?? selected.toDouble());
              final pill = Center(
                child: Container(
                  width: slot - 24,
                  height: height - 16,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                ),
              );
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  // Sliding highlight pill. With a fraction it tracks the
                  // swipe live (plain Positioned); without one it animates
                  // between integer slots on tap.
                  if (selectedFraction != null)
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
                              onTap: () => onSelect(i),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
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
        padding: EdgeInsets.only(bottom: bottomInset),
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
        // safe-area inset.
        padding: EdgeInsets.only(
          top: hugTopCorners ? hugRadius : 0,
          bottom: bottomInset,
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  final _NavItemData data;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        onTap: onTap,
        child: Center(
          child: _badged(
            AnimatedScale(
              // Small bounce on selection — easeOutBack overshoots past 1.0
              // then settles, so the active icon "pops".
              scale: selected ? 1.18 : 1.0,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  selected ? data.selectedIcon : data.icon,
                  key: ValueKey(selected),
                  size: 22,
                  // Colour transition white → cyan accent on selection (the
                  // AnimatedSwitcher cross-fades between the two icons).
                  color: selected
                      ? SC.accent
                      : Colors.white.withValues(alpha: 0.78),
                ),
              ),
            ),
            data.badge,
          ),
        ),
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
