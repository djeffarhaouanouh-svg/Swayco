import 'package:flutter/widgets.dart';

/// Compact-on-scroll signal for the floating GlassNavBar. Screens that
/// host the bottom scroll surface (Chat list, Discover, Demandes,
/// Profile) feed pixel-delta events into [onScroll] and the nav bar
/// reads [collapsed] to swap between its full and minimised layouts —
/// the iOS-26 Liquid-Glass behaviour where the tab bar shrinks down
/// to just the active tab as you scroll into a long list and pops
/// back open as you scroll up.
///
/// The notifier is global because the GlassNavBar is rendered by
/// [RootShell] (and the floating one on ProfileScreen) but is driven
/// by whichever child tab is currently visible. A shared notifier
/// avoids drilling the controller down through the tree.
abstract final class NavBarVisibility {
  static final ValueNotifier<bool> collapsed = ValueNotifier<bool>(false);

  /// Hysteresis threshold (px) before we flip the state — keeps tiny
  /// finger jitter from rapidly toggling expand / collapse.
  static const double _threshold = 8;

  static double _accDown = 0;
  static double _accUp = 0;

  /// Feed a [ScrollNotification] in (or any signed pixel delta) and
  /// the collapsed state updates accordingly. Safe to call with any
  /// notification type — [ScrollUpdateNotification] is the only one
  /// that contributes, the rest reset the accumulator.
  static void onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification) {
      _accDown = 0;
      _accUp = 0;
      return;
    }
    final delta = n.scrollDelta ?? 0;
    if (delta > 0) {
      _accDown += delta;
      _accUp = 0;
      if (_accDown >= _threshold && !collapsed.value) {
        collapsed.value = true;
      }
    } else if (delta < 0) {
      _accUp += -delta;
      _accDown = 0;
      if (_accUp >= _threshold && collapsed.value) {
        collapsed.value = false;
      }
    }
  }

  /// Force the bar back to expanded — used on tab change so a swap
  /// never lands the user on a minimised bar with no visual cue.
  static void reveal() {
    _accDown = 0;
    _accUp = 0;
    if (collapsed.value) collapsed.value = false;
  }
}
