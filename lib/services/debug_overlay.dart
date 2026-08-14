import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Append a line to the on-screen debug overlay — tap the 🐛 (top right) to
// reveal the panel. On in every build EXCEPT a plain release; see [init].
// Usage: DebugOverlay.log('[sway-rt] something happened');
class DebugOverlay extends StatefulWidget {
  const DebugOverlay({super.key, required this.child});

  final Widget child;

  static final ValueNotifier<List<String>> _lines = ValueNotifier([]);
  static bool _enabled = false;

  /// Allume l'overlay dans une build RELEASE. À passer au moment de la
  /// compilation :
  ///
  ///   flutter build ipa --dart-define=DEBUG_OVERLAY=true
  ///
  /// C'est le seul cas qui demande un drapeau, et c'est voulu — voir [init].
  static const bool _releaseOverride =
      bool.fromEnvironment('DEBUG_OVERLAY');

  static void init() {
    // Partout SAUF dans une release nue.
    //
    // Il a été allumé pour tout le monde, release signée comprise, parce que
    // les pannes intéressantes vivent justement là — le modèle qui ne charge
    // que sur un vrai téléphone, le décodage qui ne rame que sur ARM. Puis
    // éteint partout (e4e4228), parce que l'icône 🐛 s'affichait alors chez
    // quiconque tenait le téléphone.
    //
    // Les deux avaient raison, et c'est le tout-ou-rien qui était faux. En
    // debug et en profil, il est là sans qu'on ait à y penser : aucun drapeau
    // à se rappeler au moment précis où on l'a déjà oublié, ce qui était le
    // reproche fait au `--dart-define`. En release il faut le demander — et
    // une build de magasin, qui ne le demande pas, n'a plus rien à montrer.
    _enabled = !kReleaseMode || _releaseOverride;
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Copy-all bar: notification/on-screen logs can't be
                      // copy-pasted, so this dumps every buffered line into
                      // the clipboard in one tap.
                      Row(
                        children: [
                          Text(
                            '${lines.length} lignes',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () async {
                              await Clipboard.setData(
                                ClipboardData(text: lines.join('\n')),
                              );
                              if (!context2.mounted) return;
                              ScaffoldMessenger.of(context2).showSnackBar(
                                SnackBar(
                                  content: Text('${lines.length} lignes copiées'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.greenAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.greenAccent.withValues(alpha: 0.6),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.copy,
                                      color: Colors.greenAccent, size: 12),
                                  SizedBox(width: 4),
                                  Text(
                                    'Copier tout',
                                    style: TextStyle(
                                      color: Colors.greenAccent,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // SelectionArea lets you also drag-select a single line
                      // if you only want part of the buffer.
                      Expanded(
                        child: SelectionArea(
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
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
