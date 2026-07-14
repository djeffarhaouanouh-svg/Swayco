import 'package:flutter/foundation.dart';

/// Lets a page ask the shell to get out of the way. When the Discover card is
/// pulled up into its info panel, the floating nav bar slides away so the panel
/// owns the bottom of the screen; dropping the card back brings it in.
///
/// A plain notifier rather than an InheritedWidget: the nav bar lives in
/// RootShell, several widgets above the page that needs to hide it.
abstract final class NavChrome {
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);

  static void hide() => hidden.value = true;
  static void show() => hidden.value = false;
}
