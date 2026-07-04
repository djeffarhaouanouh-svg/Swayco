import 'package:cupertino_native_plus/cupertino_native_plus.dart';
import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// Apple's NATIVE iOS 26 "liquid glass" tab bar (UITabBar via platform view),
/// used on iOS in place of the app's own [GlassNavBar]. Mirrors the same four
/// tabs, labels and unread badges so the rest of the app keeps driving
/// selection through the existing [onSelect] / [selected] contract.
///
/// On iOS < 26 the underlying [CNTabBar] falls back to a native
/// [CupertinoTabBar]; Android/web never build this widget (RootShell keeps the
/// custom glass bar there).
class NativeTabBar extends StatelessWidget {
  const NativeTabBar({
    super.key,
    required this.selected,
    required this.unreadChat,
    required this.unreadRequests,
    required this.onSelect,
  });

  final int selected;
  final int unreadChat;
  final int unreadRequests;
  final ValueChanged<int> onSelect;

  /// Badge string for a count: null hides it, otherwise a capped "99+" label.
  static String? _badge(int count) {
    if (count <= 0) return null;
    return count > 99 ? '99+' : '$count';
  }

  @override
  Widget build(BuildContext context) {
    return CNTabBar(
      currentIndex: selected,
      onTap: onSelect,
      tint: SC.accent,
      items: [
        CNTabBarItem(
          label: AppStrings.t('nav_chat'),
          icon: CNIcon.symbol('bubble.left'),
          activeIcon: CNIcon.symbol('bubble.left.fill'),
          badge: _badge(unreadChat),
        ),
        CNTabBarItem(
          // Card-stack glyph — Discover deck metaphor.
          label: AppStrings.t('nav_search'),
          icon: CNIcon.symbol('square.stack'),
          activeIcon: CNIcon.symbol('square.stack.fill'),
        ),
        CNTabBarItem(
          label: AppStrings.t('nav_demandes'),
          icon: CNIcon.symbol('heart'),
          activeIcon: CNIcon.symbol('heart.fill'),
          badge: _badge(unreadRequests),
        ),
        CNTabBarItem(
          label: AppStrings.t('nav_tab3'),
          icon: CNIcon.symbol('person'),
          activeIcon: CNIcon.symbol('person.fill'),
        ),
      ],
    );
  }
}
