import 'package:cupertino_native_plus/cupertino_native_plus.dart'
    show PlatformVersion;

/// Whether Apple's NATIVE Liquid Glass (platform-view) effects are available:
/// true only on iOS 26+ / macOS 26+. False on Android, web and older Apple
/// OSes — callers fall back to the app's own (shader / BackdropFilter) glass.
///
/// Single source of truth so screens don't import the package directly and
/// the gate can be tweaked in one place.
bool get useNativeGlass => PlatformVersion.shouldUseNativeGlass;
