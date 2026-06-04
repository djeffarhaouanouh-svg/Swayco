import 'package:flutter/widgets.dart';

/// App-wide navigator key. Lets code that runs outside the widget tree —
/// e.g. the iOS CallKit "accept" handler, which fires from a native event
/// while the app may still be in the background — push routes reliably,
/// without depending on a particular BuildContext being mounted/visible.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
