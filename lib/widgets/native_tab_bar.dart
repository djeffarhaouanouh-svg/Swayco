import 'dart:ui';

import 'package:cupertino_native_plus/cupertino_native_plus.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../services/app_strings.dart';
import '../theme/swayco_theme.dart';

/// The four Discover tabs, described once and shared by BOTH renderers below
/// (native [CNTabBar] on iOS, Flutter look-alike on web) so labels, order and
/// badge wiring never drift apart.
class _TabSpec {
  const _TabSpec({
    required this.label,
    required this.sfSymbol,
    required this.sfSymbolActive,
    required this.icon,
    required this.iconActive,
  });

  final String label;
  final String sfSymbol; // Apple SF Symbol (native only)
  final String sfSymbolActive;
  final IconData icon; // Material glyph (web / non-Apple)
  final IconData iconActive;
}

/// Apple-style tab bar for the app's four Discover tabs.
///
/// - **Native iOS** → the real UIKit [CNTabBar] (iOS 26 "liquid glass", or a
///   native [CupertinoTabBar] on iOS < 26). SF Symbols render because they're
///   an Apple system resource.
/// - **Web / everything else** → a Flutter recreation styled to match iOS 26,
///   drawn with Material glyphs (SF Symbols don't exist off-Apple, so they'd be
///   blank). This is why the web path can't use [CNTabBar] directly.
///
/// Android keeps the app's own floating glass bar (RootShell only builds this
/// widget on iOS or web).
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

  static List<_TabSpec> _specs() => [
        _TabSpec(
          label: AppStrings.t('nav_chat'),
          sfSymbol: 'bubble.left',
          sfSymbolActive: 'bubble.left.fill',
          icon: Icons.chat_bubble_outline,
          iconActive: Icons.chat_bubble,
        ),
        _TabSpec(
          // Card-stack glyph — Discover deck metaphor.
          label: AppStrings.t('nav_search'),
          sfSymbol: 'square.stack',
          sfSymbolActive: 'square.stack.fill',
          icon: Icons.style_outlined,
          iconActive: Icons.style,
        ),
        _TabSpec(
          label: AppStrings.t('nav_demandes'),
          sfSymbol: 'heart',
          sfSymbolActive: 'heart.fill',
          icon: Icons.favorite_border,
          iconActive: Icons.favorite,
        ),
        _TabSpec(
          label: AppStrings.t('nav_tab3'),
          sfSymbol: 'person',
          sfSymbolActive: 'person.fill',
          icon: Icons.person_outline,
          iconActive: Icons.person,
        ),
      ];

  /// Badge string for a count: null hides it, otherwise a capped "99+" label.
  static String? _badge(int count) {
    if (count <= 0) return null;
    return count > 99 ? '99+' : '$count';
  }

  @override
  Widget build(BuildContext context) {
    final specs = _specs();
    final badges = [unreadChat, 0, unreadRequests, 0];

    // Real native platform view only on Apple; web/others get the recreation.
    final useNative =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

    if (useNative) {
      return CNTabBar(
        currentIndex: selected,
        onTap: onSelect,
        tint: SC.accent,
        items: [
          for (var i = 0; i < specs.length; i++)
            CNTabBarItem(
              label: specs[i].label,
              icon: CNIcon.symbol(specs[i].sfSymbol),
              activeIcon: CNIcon.symbol(specs[i].sfSymbolActive),
              badge: _badge(badges[i]),
            ),
        ],
      );
    }

    return _CupertinoStyleTabBar(
      specs: specs,
      badges: badges,
      selected: selected,
      onSelect: onSelect,
    );
  }
}

/// Flutter recreation of the iOS 26 tab bar for the web build: a translucent
/// blurred glass bar flush to the bottom edge, icon-over-label items, tinted
/// selection, red count badges. Works anywhere Flutter runs.
class _CupertinoStyleTabBar extends StatelessWidget {
  const _CupertinoStyleTabBar({
    required this.specs,
    required this.badges,
    required this.selected,
    required this.onSelect,
  });

  final List<_TabSpec> specs;
  final List<int> badges;
  final int selected;
  final ValueChanged<int> onSelect;

  static const double _barHeight = 50;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: EdgeInsets.only(bottom: safeBottom),
          decoration: BoxDecoration(
            color: SC.bgDeep.withValues(alpha: 0.72),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.10),
                width: 0.5,
              ),
            ),
          ),
          child: SizedBox(
            height: _barHeight,
            child: Row(
              children: [
                for (var i = 0; i < specs.length; i++)
                  Expanded(
                    child: _TabButton(
                      spec: specs[i],
                      badge: badges[i],
                      active: selected == i,
                      onTap: () => onSelect(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.spec,
    required this.badge,
    required this.active,
    required this.onTap,
  });

  final _TabSpec spec;
  final int badge;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? SC.accent : Colors.white.withValues(alpha: 0.55);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _badged(
            Icon(active ? spec.iconActive : spec.icon, size: 25, color: color),
            badge,
          ),
          const SizedBox(height: 3),
          Text(
            spec.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _badged(Widget child, int count) {
    if (count <= 0) return child;
    return Badge.count(
      count: count,
      backgroundColor: const Color(0xFFFF3B30),
      textColor: Colors.white,
      child: child,
    );
  }
}
