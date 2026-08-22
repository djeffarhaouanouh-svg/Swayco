import 'package:flutter/material.dart';

// Was an on-screen 🐛 overlay; the visual panel is gone but the call sites
// sprinkled through the STT/call/presence code still want a log sink, so
// this now just forwards to debugPrint.
// Usage: DebugOverlay.log('[sway-rt] something happened');
abstract final class DebugOverlay {
  static void log(String msg) {
    debugPrint('[DBG] $msg');
  }
}
