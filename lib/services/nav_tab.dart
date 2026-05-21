import 'package:flutter/foundation.dart';

/// The tab currently selected in [RootShell]'s bottom nav, exposed as a
/// shared notifier so screens pushed *on top* of the shell (a peer's
/// profile, the friends list, …) can render the same nav bar and switch
/// tabs without holding a reference to the shell's private state.
///
/// Tab indices match [RootShell]'s page list: Chat 0, Discover 1, Live 2,
/// Profile 3. Defaults to Discover, the launch tab.
abstract final class NavTab {
  static const int chat = 0;
  static const int discover = 1;
  static const int live = 2;
  static const int profile = 3;

  static final ValueNotifier<int> index = ValueNotifier<int>(discover);

  /// Switch to tab [i]. No-op when it's already selected.
  static void select(int i) {
    if (i != index.value) index.value = i;
  }
}
