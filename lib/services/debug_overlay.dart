import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Append a line to the on-screen debug overlay.
// Only active when kDebugMode OR when the ?debug=1 URL param is present.
// Usage: DebugOverlay.log('[sway-rt] something happened');
class DebugOverlay extends StatefulWidget {
  const DebugOverlay({super.key, required this.child});

  final Widget child;

  static final ValueNotifier<List<String>> _lines = ValueNotifier([]);
  static bool _enabled = false;

  /// Escape hatch for a signed release you cannot attach a debugger to:
  ///   flutter build ipa --dart-define=DEBUG_OVERLAY=true
  /// Without it a TestFlight build discards every log line — exactly when you
  /// most need them.
  static const bool _forced = bool.fromEnvironment('DEBUG_OVERLAY');

  static void init() {
    // Always on for web (tap 🐛 to reveal). Native = debug builds, or a release
    // deliberately instrumented with --dart-define=DEBUG_OVERLAY=true.
    _enabled = kIsWeb || kDebugMode || _forced;
  }

  static void log(String msg) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final lines = List<String>.from(_lines.value);
    lines.add('[$ts] $msg');
    if (lines.length > 120) lines.removeRange(0, lines.length - 120);
    _lines.value = lines;
    debugPrint('[DBG] $msg');
  }

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  bool _visible = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!DebugOverlay._enabled) return widget.child;
    return Stack(
      children: [
        widget.child,
        // Tap-to-toggle button
        Positioned(
          top: 60,
          right: 6,
          child: GestureDetector(
            onTap: () => setState(() => _visible = !_visible),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _visible ? Icons.close : Icons.bug_report,
                color: Colors.greenAccent,
                size: 16,
              ),
            ),
          ),
        ),
        if (_visible)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).size.height * 0.4,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: DebugOverlay._lines,
              builder: (context2, lines, child2) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scroll.hasClients) {
                    _scroll.jumpTo(_scroll.position.maxScrollExtent);
                  }
                });
                return Container(
                  color: Colors.black.withValues(alpha: 0.88),
                  padding: const EdgeInsets.all(6),
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Text(
                      lines[i],
                      style: const TextStyle(
                        color: Color(0xFF00FF00),
                        fontSize: 10,
                        fontFamily: 'monospace',
                        height: 1.3,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
