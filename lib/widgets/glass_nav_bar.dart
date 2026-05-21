import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/whatsapp_call_theme.dart';

/// Floating glass-morphism bottom-nav with a sliding pill that animates
/// between selected tabs. Rendered by [RootShell] and re-used by screens
/// pushed on top of it (e.g. a peer's profile) so the bar stays visible.
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.selected,
    required this.unreadChat,
    required this.onSelect,
  });

  final int selected;
  final int unreadChat;
  final ValueChanged<int> onSelect;

  static const double _height = 54;
  static const double _itemWidth = 72;
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
        icon: Icons.search,
        selectedIcon: Icons.manage_search,
        label: AppStrings.t('nav_search'),
      ),
      const _NavItemData(
        icon: Icons.public,
        selectedIcon: Icons.travel_explore,
        label: 'Live',
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
              // Sliding highlight pill — animates between item slots.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
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
                        onTap: () => onSelect(i),
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
                color: selected
                    ? WhatsAppCallTheme.accent
                    : Colors.white.withValues(alpha: 0.78),
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
      backgroundColor: WhatsAppCallTheme.danger,
      textColor: Colors.white,
      child: child,
    );
  }
}
