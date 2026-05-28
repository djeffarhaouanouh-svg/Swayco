import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// Floating glass-morphism bottom-nav with a sliding pill that animates
/// between selected tabs. Rendered by [RootShell] and re-used by screens
/// pushed on top of it (e.g. a peer's profile) so the bar stays visible.
///
/// Premium-feel details: spring-out pill motion, cyan halo under the
/// active slot, soft icon zoom + selection-click haptic on tap, and a
/// brief press-squeeze on the icon being released. The whole thing
/// sits on a heavy BackdropFilter so it reads as frosted glass over
/// whatever's behind.
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

    final totalWidth = _hPad * 2 + _itemWidth * items.length;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          width: totalWidth,
          height: _height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.20),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 6),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Sliding highlight pill — spring-out curve gives a tiny
              // overshoot/bounce when it lands on a new slot. The cyan
              // halo underneath is what makes the active tab feel
              // "lit up" instead of just tinted.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 420),
                curve: Curves.elasticOut,
                left: _itemWidth * selected,
                top: 0,
                bottom: 0,
                width: _itemWidth,
                child: Center(
                  child: Container(
                    width: _itemWidth - 4,
                    height: _height - 16,
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
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Items.
              Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    SizedBox(
                      width: _itemWidth,
                      height: _height,
                      child: _NavItem(
                        data: items[i],
                        selected: selected == i,
                        onTap: () {
                          // Light haptic so the press registers
                          // physically before the visual transition
                          // even starts.
                          HapticFeedback.selectionClick();
                          onSelect(i);
                        },
                      ),
                    ),
                ],
              ),
            ],
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
    // Selected icons get a permanent 1.12 scale so the active slot
    // reads as "bigger / louder". The press state stacks on top with
    // a brief squeeze to ~0.88. AnimatedScale handles both with a
    // 140 ms ease curve.
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
                // Keep every nav icon white; the sliding pill behind
                // the selected one already signals which tab is
                // active. Selected gets a slight luminance boost via
                // a soft white shadow to lift it off the pill.
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
