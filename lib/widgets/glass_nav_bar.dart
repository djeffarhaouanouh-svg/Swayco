import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';

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
  });

  final int selected;
  final int unreadChat;

  /// Count of pending friend requests addressed to the local user —
  /// drives the red badge on the Demandes tab.
  final int unreadRequests;
  final ValueChanged<int> onSelect;

  /// Height of the bar's content row (excludes the bottom safe-area inset,
  /// which the bar pads internally). Exposed so screens that let content
  /// run behind the bar — e.g. the full-bleed Discover card — can reserve
  /// exactly this much space and sit flush against the bar's top edge.
  static const double height = 56;

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
        // Card-stack glyph (Discover deck metaphor) replaces the
        // magnifier — search now lives in the dedicated bar at the
        // top of the Discover tab, so the icon no longer needed to
        // read as "search".
        icon: Icons.style_outlined,
        selectedIcon: Icons.style,
        label: AppStrings.t('nav_search'),
      ),
      _NavItemData(
        icon: Icons.group_outlined,
        selectedIcon: Icons.group,
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

    return ClipRRect(
      // Rounded top corners so the bar curves up around the bottom corners
      // of the Discover photo (and reads as a soft glass shelf on the other
      // tabs too).
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          padding: EdgeInsets.only(bottom: bottomInset),
          child: SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Each tab gets an equal slice of the full width; the pill
                // and the icons share the same slot geometry so they line up.
                final slot = constraints.maxWidth / items.length;
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    // Sliding highlight pill — animates between item slots.
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      left: slot * selected,
                      top: 0,
                      bottom: 0,
                      width: slot,
                      child: Center(
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
                      ),
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
          ),
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
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(
                selected ? data.selectedIcon : data.icon,
                key: ValueKey(selected),
                size: 22,
                // Keep every nav icon white; the sliding pill behind
                // the selected one already signals which tab is
                // active, so tinting the icon cyan on hover / select
                // was visual noise.
                color: Colors.white.withValues(alpha: selected ? 1.0 : 0.78),
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
