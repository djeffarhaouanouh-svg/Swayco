import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cupertino_native_plus/cupertino_native_plus.dart'
    show PlatformVersion;

/// Whether Apple's NATIVE Liquid Glass (platform-view) effects are available:
/// true only on iOS 26+ / macOS 26+. False on Android, web and older Apple
/// OSes — callers fall back to the app's own (shader / BackdropFilter) glass.
///
/// IMPORTANT: the `!kIsWeb` guard MUST come first. [PlatformVersion] reads
/// `dart:io`'s `Platform`, which is unsupported on Flutter web and throws —
/// and Chrome-on-iPhone reports `TargetPlatform.iOS`, so without this guard
/// the web build would crash into the native path. Short-circuiting on web
/// never touches `dart:io`.
///
/// Single source of truth so screens don't import the package directly and
/// the gate can be tweaked in one place.
bool get useNativeGlass => !kIsWeb && PlatformVersion.shouldUseNativeGlass;
