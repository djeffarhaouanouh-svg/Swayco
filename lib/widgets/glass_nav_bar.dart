import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../services/nav_bar_visibility.dart';
import '../theme/swayco_theme.dart';

/// Floating glass-morphism bottom-nav with a sliding pill that animates
/// between selected tabs. Rendered by [RootShell] and re-used by screens
/// pushed on top of it (e.g. a peer's profile) so the bar stays visible.
///
/// iOS-26 Liquid-Glass behaviour:
///   • collapses to just the active tab while the user scrolls down
///     a long list (driven by [NavBarVisibility]) and pops back open
///     on scroll-up,
///   • subtle refraction gradient overlay so the surface reads as
///     light-reactive rather than flat white-alpha,
///   • cyan halo under the active pill, selection-click haptic, spring
///     bounce on the pill, soft icon scale on press + selected.
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

  static const double _height = 54;
  static const double _itemWidth = 64;
  static const double _hPad = 10;

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

    final expandedWidth = _hPad * 2 + _itemWidth * items.length;
    final collapsedWidth = _itemWidth + _hPad * 2;

    return ValueListenableBuilder<bool>(
      valueListenable: NavBarVisibility.collapsed,
      builder: (_, collapsed, _) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          width: collapsed ? collapsedWidth : expandedWidth,
          height: _height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
              child: Stack(
                children: [
                  // Base translucent fill + border.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.20),
                        ),
                      ),
                    ),
                  ),
                  // Refraction overlay — a slim diagonal white-alpha
                  // gradient that simulates the light bleed across a
                  // glass surface. Subtle on purpose; under the
                  // backdrop blur it reads as a highlight, not a tint.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.18),
                            Colors.white.withValues(alpha: 0.0),
                            Colors.white.withValues(alpha: 0.08),
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _hPad,
                      vertical: 6,
                    ),
                    child: _NavContent(
                      items: items,
                      selected: selected,
                      collapsed: collapsed,
                      itemWidth: _itemWidth,
                      height: _height,
                      onSelect: (i) {
                        HapticFeedback.selectionClick();
                        NavBarVisibility.reveal();
                        onSelect(i);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Inner row of items + sliding pill. Split out so the AnimatedContainer
/// above can resize cleanly while this widget cross-fades between the
/// expanded (4 items) and collapsed (just-selected) layouts.
class _NavContent extends StatelessWidget {
  const _NavContent({
    required this.items,
    required this.selected,
    required this.collapsed,
    required this.itemWidth,
    required this.height,
    required this.onSelect,
  });

  final List<_NavItemData> items;
  final int selected;
  final bool collapsed;
  final double itemWidth;
  final double height;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        // Sliding pill. In collapsed mode it sits at index 0 because
        // only the selected item is rendered; in expanded mode it
        // walks across the row with an elastic-out spring.
        AnimatedPositioned(
          duration: const Duration(milliseconds: 420),
          curve: Curves.elasticOut,
          left: collapsed ? 0 : itemWidth * selected,
          top: 0,
          bottom: 0,
          width: itemWidth,
          child: Center(
            child: Container(
              width: itemWidth - 4,
              height: height - 16,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: SC.accent.withValues(alpha: 0.30),
                    blurRadius: 16,
                  ),
                ],
              ),
            ),
          ),
        ),
        // Item row. AnimatedSwitcher gives a soft cross-fade between
        // the full row and the single-active layout when collapse /
        // expand toggles.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: collapsed
              ? SizedBox(
                  key: const ValueKey('collapsed'),
                  width: itemWidth,
                  height: height,
                  child: _NavItem(
                    data: items[selected],
                    selected: true,
                    onTap: () => onSelect(selected),
                  ),
                )
              : Row(
                  key: const ValueKey('expanded'),
                  children: [
                    for (var i = 0; i < items.length; i++)
                      SizedBox(
                        width: itemWidth,
                        height: height,
                        child: _NavItem(
                          data: items[i],
                          selected: selected == i,
                          onTap: () => onSelect(i),
                        ),
                      ),
                  ],
                ),
        ),
      ],
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

/// Single tab inside the glass bar. Stateful so we can run a
/// press-squeeze on tap-down (icon scales to ~0.88) and let go on
/// tap-up — same micro-feedback Apple uses on the App Store / Mail
/// tab bars.
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  final _NavItemData data;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = _pressed
        ? 0.88
        : widget.selected
            ? 1.12
            : 1.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Center(
        child: _badged(
          AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(
                widget.selected
                    ? widget.data.selectedIcon
                    : widget.data.icon,
                key: ValueKey(widget.selected),
                size: 22,
                color: Colors.white.withValues(
                  alpha: widget.selected ? 1.0 : 0.78,
                ),
                shadows: widget.selected
                    ? [
                        Shadow(
                          color: Colors.white.withValues(alpha: 0.55),
                          blurRadius: 12,
                        ),
                      ]
                    : null,
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
      backgroundColor: const Color(0xFFE53935),
      textColor: Colors.white,
      child: child,
    );
  }
}
